<#
.SYNOPSIS
    Builds a Windows container image without Docker: one layer with a folder of files on top
    of a base image pulled by pull-image.ps1, written as an OCI image layout.

.DESCRIPTION
    The steps of part 7 of "Windows containers by hand":

      1. a writable layer over the base image layers (wclayer create), mounted to a folder;
         the source folder is copied into it, and wclayer export turns the changes into a
         layer tar: Files\ with the new files and Hives\ with the registry deltas;
      2. the tar is compressed; its sha256 is the diff_id, the sha256 of the .tar.gz the digest;
      3. the image config is the base config with the new diff_id, a history entry and
         the command, working directory and user of the new image;
      4. the manifest lists the config and the layers, the base ones first;
      5. the manifest goes into index.json of the layout with the platform of the base image,
         os.version included, next to the manifests already there.

    Run it once per base image to get an index with one manifest per Windows build.
    An OCI image layout is a folder with oci-layout, index.json and blobs\sha256\<hex>.

.EXAMPLE
    .\build-image.ps1 C:\images\nanoserver C:\lab\app C:\lab\hello -Cmd cmd, /c, C:\app\hello.cmd
#>
param(
    [Parameter(Mandatory)] [string] $Base,
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Layout,
    [string] $Target = 'C:\app',
    [string[]] $Cmd = @(),
    [string] $WorkingDir = $Target,
    [string] $User = 'ContainerUser',
    [string] $Wclayer = 'C:\hcs\wclayer.exe'
)
$ErrorActionPreference = 'Stop'

$utf8 = New-Object Text.UTF8Encoding $false
function Get-Sha256([string] $path) { 'sha256:' + (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() }

# Writes text as a blob of the layout and returns its descriptor.
function Add-Blob([string] $mediaType, [string] $text) {
    $tmp = Join-Path $blobs 'blob.tmp'
    [IO.File]::WriteAllText($tmp, $text, $utf8)
    $digest = Get-Sha256 $tmp
    Move-Item $tmp (Join-Path $blobs ($digest -replace '^sha256:')) -Force
    [ordered]@{ mediaType = $mediaType; digest = $digest; size = (Get-Item (Join-Path $blobs ($digest -replace '^sha256:'))).Length }
}

$blobs = Join-Path $Layout 'blobs\sha256'
New-Item -ItemType Directory $blobs -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $Layout 'oci-layout'), '{"imageLayoutVersion":"1.0.0"}', $utf8)

# Windows PowerShell 5.1 returns a JSON array as one object; the second pipeline unrolls it.
$baseLayers = @(Get-Content (Join-Path $Base 'layers.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$baseManifest = Get-Content (Join-Path $Base 'manifest.json') -Raw | ConvertFrom-Json
$config = Get-Content (Join-Path $Base 'image.json') -Raw | ConvertFrom-Json

# 1. The layer: a writable layer over the base, the files copied in, the changes exported.
$work = Join-Path $env:TEMP "build-image-$PID"
$scratch = Join-Path $work 'scratch'
$mnt = Join-Path $work 'mnt'
New-Item -ItemType Directory $mnt -Force | Out-Null
$l = foreach ($p in $baseLayers) { '-l'; $p }
& $Wclayer create @l $scratch
if ($LASTEXITCODE) { throw 'wclayer create failed' }
& $Wclayer mount @l $scratch $mnt | Out-Null
if ($LASTEXITCODE) { throw 'wclayer mount failed' }
try {
    $dest = Join-Path $mnt ($Target -replace '^[A-Za-z]:\\', '')
    New-Item -ItemType Directory $dest -Force | Out-Null
    Copy-Item (Join-Path $Source '*') $dest -Recurse -Force
} finally {
    mountvol $mnt /D
    & $Wclayer unmount $scratch
}
# wclayer export -z leaves an empty gzip stream behind (hcsshim 0.15.0), so compress here.
$tar = Join-Path $work 'layer.tar'
& $Wclayer export @l -o $tar $scratch
if ($LASTEXITCODE) { throw 'wclayer export failed' }

# 2. diff_id of the tar, digest of the .tar.gz.
$diffId = Get-Sha256 $tar
$gz = Join-Path $work 'layer.tar.gz'
$in = [IO.File]::OpenRead($tar)
$out = [IO.File]::Create($gz)
$zip = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionMode]::Compress)
try { $in.CopyTo($zip) } finally { $zip.Dispose(); $out.Dispose(); $in.Dispose() }
$layerDigest = Get-Sha256 $gz
Move-Item $gz (Join-Path $blobs ($layerDigest -replace '^sha256:')) -Force
$layer = [ordered]@{ mediaType = 'application/vnd.oci.image.layer.v1.tar+gzip'; digest = $layerDigest; size = (Get-Item (Join-Path $blobs ($layerDigest -replace '^sha256:'))).Length }
& $Wclayer remove $scratch
Remove-Item $work -Recurse -Force
Write-Host "layer  $layerDigest  diff_id $diffId"

# The base layers: the same compressed blobs, under the OCI media type.
$layers = @(foreach ($b in $baseManifest.layers) {
    Copy-Item (Join-Path $Base "blobs\sha256\$($b.digest -replace '^sha256:')") $blobs -Force
    [ordered]@{ mediaType = 'application/vnd.oci.image.layer.v1.tar+gzip'; digest = $b.digest; size = $b.size }
}) + $layer

# 3. The config: the base config, one more diff_id and history entry, the new command.
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$config.created = $now
$config.config.Cmd = $Cmd
$config.config.WorkingDir = $WorkingDir
$config.config.User = $User
$config.rootfs.diff_ids = @($config.rootfs.diff_ids) + $diffId
$config.history = @($config.history) + [pscustomobject]@{ created = $now; created_by = "build-image.ps1: $Source -> $Target" }
$configDesc = Add-Blob 'application/vnd.oci.image.config.v1+json' ($config | ConvertTo-Json -Depth 10 -Compress)
Write-Host "config $($configDesc.digest)"

# 4. The manifest.
$manifest = [ordered]@{
    schemaVersion = 2
    mediaType = 'application/vnd.oci.image.manifest.v1+json'
    config = $configDesc
    layers = $layers
}
$manifestDesc = Add-Blob 'application/vnd.oci.image.manifest.v1+json' ($manifest | ConvertTo-Json -Depth 10 -Compress)
Write-Host "manifest $($manifestDesc.digest)"

# 5. The index of the layout: one manifest per platform; a rebuild for the same os.version replaces it.
$indexFile = Join-Path $Layout 'index.json'
$entries = @()
if (Test-Path $indexFile) {
    $entries = @((Get-Content $indexFile -Raw | ConvertFrom-Json).manifests | ForEach-Object { $_ } |
        Where-Object { $_.platform.'os.version' -ne $config.'os.version' })
}
$manifestDesc.platform = [ordered]@{ architecture = $config.architecture; os = $config.os; 'os.version' = $config.'os.version' }
$index = [ordered]@{
    schemaVersion = 2
    mediaType = 'application/vnd.oci.image.index.v1+json'
    manifests = @($entries) + [pscustomobject]$manifestDesc
}
[IO.File]::WriteAllText($indexFile, ($index | ConvertTo-Json -Depth 10 -Compress), $utf8)
Write-Host "index  $($config.'os.version') added, $(@($index.manifests).Count) manifests"
