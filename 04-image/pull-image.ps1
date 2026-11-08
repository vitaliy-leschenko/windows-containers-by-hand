<#
.SYNOPSIS
    Pulls a Windows container image from a registry without containerd and imports its layers.

.DESCRIPTION
    Speaks the OCI distribution API with curl.exe: resolves the tag to an image index,
    picks the manifest whose os.version has the build of this host, downloads the config
    and the layers, checks every digest and every diff_id, and imports the layers with
    wclayer.exe, each on top of the previous ones.

    Result in -Dir:
      blobs\sha256\<hex>   the manifest, the config and the compressed layers as downloaded
      layers\<diff_id>     one imported layer per folder
      manifest.json        the image manifest
      image.json           the image config
      layers.json          the layer folders from the top layer down to the base layer,
                           the order wclayer -l and HCS expect

    Anonymous pulls only: a registry that answers 401 gets the token it asks for in
    WWW-Authenticate, without a user name or password.

.EXAMPLE
    .\pull-image.ps1 mcr.microsoft.com/windows/nanoserver:ltsc2025 C:\images\nanoserver
#>
param(
    [Parameter(Mandatory)] [string] $Image,
    [Parameter(Mandatory)] [string] $Dir,
    # The Windows build to pick from an index; by default the build of this host.
    [string] $Build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild,
    [string] $Wclayer = 'C:\hcs\wclayer.exe'
)

$ErrorActionPreference = 'Stop'

$indexTypes = 'application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json'
$manifestTypes = 'application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'

# registry/repository:tag or registry/repository@sha256:...; Docker Hub names get library/.
if ($Image -notmatch '^(?<reg>[^/]+\.[^/]+|localhost(:\d+)?)/(?<repo>[^:@]+)(?::(?<tag>[^@]+))?(?:@(?<digest>sha256:[0-9a-f]{64}))?$') {
    throw "use registry/repository:tag, for example mcr.microsoft.com/windows/nanoserver:ltsc2025"
}
$registry = $Matches.reg
$repo = $Matches.repo
$ref = if ($Matches.digest) { $Matches.digest } elseif ($Matches.tag) { $Matches.tag } else { 'latest' }
if ($registry -eq 'docker.io') { $registry = 'registry-1.docker.io'; if ($repo -notmatch '/') { $repo = "library/$repo" } }
# A registry on this machine (part 7) speaks plain HTTP; everything else is HTTPS.
$scheme = if ($registry -match '^(localhost|127\.0\.0\.1)(:\d+)?$') { 'http' } else { 'https' }

$blobDir = Join-Path $Dir 'blobs\sha256'
New-Item -ItemType Directory $blobDir, (Join-Path $Dir 'layers') -Force | Out-Null
$script:token = $null

function Get-Sha256([string] $path) { 'sha256:' + (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() }

# GET from the registry into a file; on 401 fetch an anonymous bearer token once and retry.
function Invoke-Registry([string] $path, [string] $accept, [string] $outFile) {
    $url = "${scheme}://$registry/v2/$repo/$path"
    $hdr = "$outFile.hdr"
    for ($try = 0; $try -lt 2; $try++) {
        $curlArgs = @('-sL', '-o', $outFile, '-D', $hdr, '-w', '%{http_code}')
        if ($accept) { $curlArgs += '-H', "Accept: $accept" }
        if ($script:token) { $curlArgs += '-H', "Authorization: Bearer $($script:token)" }
        $code = curl.exe @curlArgs $url
        if ($code -eq '200') { Remove-Item $hdr; return }
        $auth = Select-String -Path $hdr -Pattern '^www-authenticate:\s*Bearer\s+(.+)$' | Select-Object -Last 1
        if ($code -ne '401' -or -not $auth -or $script:token) { throw "GET $url -> HTTP $code" }
        # Bearer realm="https://auth.example/token",service="registry",scope="repository:x:pull"
        $p = @{}
        foreach ($m in [regex]::Matches($auth.Matches[0].Groups[1].Value, '(\w+)="([^"]*)"')) { $p[$m.Groups[1].Value] = $m.Groups[2].Value }
        $q = (@('service', 'scope') | Where-Object { $p[$_] } | ForEach-Object { "$_=$([uri]::EscapeDataString($p[$_]))" }) -join '&'
        $script:token = (curl.exe -s "$($p.realm)?$q" | ConvertFrom-Json).token
    }
}

# Downloads a blob (or a manifest by digest, -Kind manifests) unless it is already there,
# and checks that its content has the digest.
function Get-Blob([string] $digest, [string] $accept, [string] $kind = 'blobs') {
    $file = Join-Path $blobDir ($digest -replace '^sha256:')
    if (-not (Test-Path $file) -or (Get-Sha256 $file) -ne $digest) {
        Invoke-Registry "$kind/$digest" $accept $file
        if ((Get-Sha256 $file) -ne $digest) { throw "${kind}/${digest}: sha256 mismatch" }
    }
    $file
}

# 1. The tag: an index with one manifest per platform, or a single manifest.
$tmp = Join-Path $blobDir 'ref.tmp'
Invoke-Registry "manifests/$ref" (($indexTypes + $manifestTypes) -join ', ') $tmp
$doc = Get-Content $tmp -Raw | ConvertFrom-Json
$digest = Get-Sha256 $tmp
$manifestFile = Join-Path $blobDir ($digest -replace '^sha256:')
Move-Item $tmp $manifestFile -Force

if ($indexTypes -contains $doc.mediaType) {
    # Process isolation needs the same build as the host: 10.0.26100.* on Windows Server 2025.
    $m = $doc.manifests |
        Where-Object { $_.platform.os -eq 'windows' -and $_.platform.architecture -eq 'amd64' -and $_.platform.'os.version' -like "10.0.$Build.*" } |
        Sort-Object { [version]$_.platform.'os.version' } | Select-Object -Last 1
    if (-not $m) { throw "no windows/amd64 manifest for build $Build in $Image" }
    Write-Host "index $digest -> $($m.platform.'os.version') $($m.digest)"
    $manifestFile = Get-Blob $m.digest $m.mediaType 'manifests'
    $doc = Get-Content $manifestFile -Raw | ConvertFrom-Json
}

# 2. The manifest names the config and the layers, the config lists the diff_ids.
Copy-Item $manifestFile (Join-Path $Dir 'manifest.json') -Force
$configFile = Get-Blob $doc.config.digest $doc.config.mediaType
Copy-Item $configFile (Join-Path $Dir 'image.json') -Force
$config = Get-Content $configFile -Raw | ConvertFrom-Json
if ($config.os -ne 'windows') { throw "$Image is a $($config.os) image" }
if ($doc.layers.Count -ne $config.rootfs.diff_ids.Count) { throw 'the manifest and the config disagree on the number of layers' }

# 3. Each layer: download, check the diff_id (sha256 of the uncompressed tar), import over the parents.
$parents = @()
for ($i = 0; $i -lt $doc.layers.Count; $i++) {
    $layer = $doc.layers[$i]
    $diffId = $config.rootfs.diff_ids[$i]
    $folder = Join-Path $Dir "layers\$($diffId -replace '^sha256:')"
    if (Test-Path (Join-Path $folder 'Files')) {
        Write-Host "layer $($i + 1)/$($doc.layers.Count) $diffId already imported"
    } else {
        if ($layer.urls) { throw "layer $($layer.digest) is a foreign layer, download it from $($layer.urls[0])" }
        $file = Get-Blob $layer.digest $layer.mediaType
        $stream = [IO.File]::OpenRead($file)
        try {
            if ($layer.mediaType -like '*gzip') { $stream = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress) }
            $sha = [Security.Cryptography.SHA256]::Create()
            $actual = 'sha256:' + (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '')
        } finally { $stream.Dispose() }
        if ($actual -ne $diffId) { throw "layer $($layer.digest): diff_id $actual, the config says $diffId" }

        if (Test-Path $folder) { & $Wclayer remove $folder }
        $wclayerArgs = @('import', '-i', $file)
        foreach ($p in $parents) { $wclayerArgs += '-l', $p }
        & $Wclayer @wclayerArgs $folder
        if ($LASTEXITCODE -ne 0) { throw "wclayer import of $($layer.digest) failed" }
        Write-Host "layer $($i + 1)/$($doc.layers.Count) $diffId imported, $($layer.size) bytes"
    }
    # The next layer sits on this one: parents go from the top layer down to the base layer.
    $parents = @($folder) + $parents
}

ConvertTo-Json @($parents) | Set-Content (Join-Path $Dir 'layers.json') -Encoding ascii
Write-Host "$Image -> $Dir, $($parents.Count) layers"
