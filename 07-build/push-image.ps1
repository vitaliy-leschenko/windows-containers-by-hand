<#
.SYNOPSIS
    Pushes an OCI image layout made by build-image.ps1 to a registry with the OCI distribution API.

.DESCRIPTION
    For every blob the manifests refer to (configs and layers): HEAD /v2/<repo>/blobs/<digest>,
    and when the registry does not have it, POST /v2/<repo>/blobs/uploads/ to open an upload and
    PUT <upload location>&digest=<digest> with the content. Then every manifest goes to
    PUT /v2/<repo>/manifests/<digest>, and the index of the layout to PUT /v2/<repo>/manifests/<tag>.

    Anonymous pushes only: the registry of part 7 runs on 127.0.0.1 without authentication.

.EXAMPLE
    .\push-image.ps1 C:\lab\hello 127.0.0.1:5000/hello:1.0
#>
param(
    [Parameter(Mandatory)] [string] $Layout,
    [Parameter(Mandatory)] [string] $Image
)
$ErrorActionPreference = 'Stop'

if ($Image -notmatch '^(?<reg>[^/]+)/(?<repo>[^:]+):(?<tag>.+)$') { throw 'use registry/repository:tag' }
$registry = $Matches.reg
$repo = $Matches.repo
$tag = $Matches.tag
$scheme = if ($registry -match '^(localhost|127\.0\.0\.1)(:\d+)?$') { 'http' } else { 'https' }
$base = "${scheme}://$registry"
$blobs = Join-Path $Layout 'blobs\sha256'
function Blob([string] $digest) { Join-Path $blobs ($digest -replace '^sha256:') }

function Push-Blob([string] $digest) {
    $code = curl.exe -s -o NUL -w '%{http_code}' -I "$base/v2/$repo/blobs/$digest"
    if ($code -eq '200') { Write-Host "blob     $digest exists"; return }
    # The registry answers the POST with 202 and the address of the upload in Location.
    $headers = curl.exe -s -o NUL -D - -X POST "$base/v2/$repo/blobs/uploads/"
    $location = ($headers | Select-String '^Location:\s*(\S+)').Matches[0].Groups[1].Value
    if ($location -notmatch '^https?://') { $location = "$base$location" }
    $sep = if ($location -match '\?') { '&' } else { '?' }
    $code = curl.exe -s -o NUL -w '%{http_code}' -X PUT -H 'Content-Type: application/octet-stream' --data-binary "@$(Blob $digest)" "$location${sep}digest=$digest"
    if ($code -ne '201') { throw "PUT blob $digest -> HTTP $code" }
    Write-Host "blob     $digest pushed, $((Get-Item (Blob $digest)).Length) bytes"
}

function Push-Manifest([string] $file, [string] $mediaType, [string] $ref) {
    $code = curl.exe -s -o NUL -w '%{http_code}' -X PUT -H "Content-Type: $mediaType" --data-binary "@$file" "$base/v2/$repo/manifests/$ref"
    if ($code -ne '201') { throw "PUT manifest $ref -> HTTP $code" }
    Write-Host "manifest $ref"
}

$indexFile = Join-Path $Layout 'index.json'
$index = Get-Content $indexFile -Raw | ConvertFrom-Json
foreach ($m in @($index.manifests)) {
    $manifest = Get-Content (Blob $m.digest) -Raw | ConvertFrom-Json
    Push-Blob $manifest.config.digest
    foreach ($layer in @($manifest.layers)) { Push-Blob $layer.digest }
    Push-Manifest (Blob $m.digest) $m.mediaType $m.digest
}
# The index of the layout is the image index: the tag points to it.
Push-Manifest $indexFile $index.mediaType $tag
