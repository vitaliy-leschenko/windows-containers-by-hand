<#
.SYNOPSIS
    Builds a HostProcess container image without Docker: a folder of files as a layer on top
    of Microsoft's HostProcess base image, written as an OCI archive for nerdctl load.

.DESCRIPTION
    The steps of part 8 of "Windows containers by hand":

      1. downloads the single layer of the base image from mcr.microsoft.com and checks its digest;
      2. packs the source folder into a layer tar with plain tar.exe: Files\<target> with the
         files and an empty Hives folder. Windows refuses to import a layer without Hives on
         top of this base image;
      3. writes the image config, the manifest and the index of an OCI image layout. There is
         no os.version in the platform: a HostProcess image runs on the kernel of the host,
         so it fits any Windows build;
      4. packs the layout into a tar that nerdctl load accepts.

    The image runs only as a HostProcess container: nerdctl run --isolation host.

.EXAMPLE
    .\build-hostprocess-image.ps1 .\app hello-hpc:1.0 -Cmd cmd, /c, '%CONTAINER_SANDBOX_MOUNT_POINT%\app\hello.cmd'
    nerdctl load -i .\hostprocess-image.tar
    nerdctl run --rm --isolation host hello-hpc:1.0
#>
param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Image,
    [Parameter(Mandatory)] [string[]] $Cmd,
    # The folder of the image the files go to: visible in the container as C:\hpc\<target>.
    [string] $Target = 'app',
    [string] $Output = (Join-Path $PWD 'hostprocess-image.tar'),
    [string] $BaseTag = 'v1.0.0'
)
$ErrorActionPreference = 'Stop'

$registry = 'https://mcr.microsoft.com/v2/oss/kubernetes/windows-host-process-containers-base-image'
$accept = 'application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
$layerType = 'application/vnd.oci.image.layer.v1.tar'
$manifestType = 'application/vnd.oci.image.manifest.v1+json'
$utf8 = New-Object Text.UTF8Encoding $false

# containerd keeps full names: hello:1.0 is docker.io/library/hello:1.0.
$ref = if ($Image -match '^[^/]+\.[^/]+/|^localhost[:/]') { $Image }
       elseif ($Image -match '/') { "docker.io/$Image" }
       else { "docker.io/library/$Image" }

$work = Join-Path $env:TEMP "build-hostprocess-image-$PID"
$blobs = Join-Path $work 'oci\blobs\sha256'
$files = Join-Path $work ("layer\Files\" + $Target)
New-Item -ItemType Directory $blobs, $files, (Join-Path $work 'layer\Hives') -Force | Out-Null

function Add-Blob([string] $file) {
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    Copy-Item $file (Join-Path $blobs $hash) -Force
    [ordered]@{ digest = "sha256:$hash"; size = (Get-Item $file).Length }
}

function Add-Json($object, [string] $name) {
    $file = Join-Path $work $name
    [IO.File]::WriteAllText($file, ($object | ConvertTo-Json -Depth 8 -Compress), $utf8)
    Add-Blob $file
}

function New-Descriptor($blob, [string] $mediaType) {
    [ordered]@{ mediaType = $mediaType; digest = $blob.digest; size = $blob.size }
}

try {
    # 1. The base layer: an uncompressed tar with two licenses and five empty registry hives.
    $index = curl.exe -sS -H "Accept: $accept" "$registry/manifests/$BaseTag" | ConvertFrom-Json
    $entry = $index.manifests | Where-Object { $_.platform.os -eq 'windows' -and $_.platform.architecture -eq 'amd64' } | Select-Object -First 1
    if (-not $entry) { throw "no windows/amd64 manifest for $BaseTag" }
    $baseManifest = curl.exe -sS -H "Accept: $accept" "$registry/manifests/$($entry.digest)" | ConvertFrom-Json
    $baseFile = Join-Path $work 'base.tar'
    curl.exe -sSL -o $baseFile "$registry/blobs/$($baseManifest.layers[0].digest)"
    if ($LASTEXITCODE) { throw 'the download of the base layer failed' }
    $baseLayer = Add-Blob $baseFile
    if ($baseLayer.digest -ne $baseManifest.layers[0].digest) { throw "base layer: digest $($baseLayer.digest), the manifest says $($baseManifest.layers[0].digest)" }
    Write-Host "base   $($baseLayer.digest), $($baseLayer.size) bytes"

    # 2. Our layer. An uncompressed tar: its digest and its diff_id are the same hash.
    Copy-Item (Join-Path $Source '*') $files -Recurse -Force
    $layerFile = Join-Path $work 'layer.tar'
    tar.exe -cf $layerFile -C (Join-Path $work 'layer') Files Hives
    if ($LASTEXITCODE) { throw 'tar failed on the layer' }
    $layer = Add-Blob $layerFile
    Write-Host "layer  $($layer.digest), $($layer.size) bytes"

    # 3. The config, the manifest and the layout.
    $config = Add-Json ([ordered]@{
        architecture = 'amd64'
        os = 'windows'
        config = [ordered]@{ Cmd = @($Cmd) }
        rootfs = [ordered]@{ type = 'layers'; diff_ids = @($baseLayer.digest, $layer.digest) }
    }) 'config.json'
    $manifest = Add-Json ([ordered]@{
        schemaVersion = 2
        mediaType = $manifestType
        config = New-Descriptor $config 'application/vnd.oci.image.config.v1+json'
        layers = @((New-Descriptor $baseLayer $layerType), (New-Descriptor $layer $layerType))
    }) 'manifest.json'
    Write-Host "manifest $($manifest.digest)"

    $entry = New-Descriptor $manifest $manifestType
    $entry.platform = [ordered]@{ architecture = 'amd64'; os = 'windows' }
    $entry.annotations = @{ 'org.opencontainers.image.ref.name' = $ref }
    $layout = Join-Path $work 'oci'
    [IO.File]::WriteAllText((Join-Path $layout 'oci-layout'), '{"imageLayoutVersion":"1.0.0"}', $utf8)
    [IO.File]::WriteAllText((Join-Path $layout 'index.json'), ([ordered]@{ schemaVersion = 2; manifests = @($entry) } | ConvertTo-Json -Depth 8 -Compress), $utf8)

    # 4. The archive for nerdctl load.
    tar.exe -cf $Output -C $layout .
    if ($LASTEXITCODE) { throw 'tar failed on the image layout' }
    Write-Host "$ref -> $Output"
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
