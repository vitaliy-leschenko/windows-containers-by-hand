<#
.SYNOPSIS
    Installs containerd, nerdctl and the Microsoft CNI plugins on Windows Server by hand.

.DESCRIPTION
    Part 1 of "Windows containers by hand". The script does exactly what the article does,
    step by step, so it can be read as a checklist:

      1. checks that the Containers feature is installed (it needs a reboot, so the script
         does not install it itself: Install-WindowsFeature Containers; Restart-Computer);
      2. downloads containerd, nerdctl and the CNI plugins from GitHub releases and checks
         their SHA-256 sums against the sums published with each release;
      3. unpacks containerd and nerdctl to C:\Program Files\containerd\bin and adds that
         folder to the machine PATH;
      4. writes the default config.toml (containerd config default);
      5. unpacks nat.exe, sdnbridge.exe and sdnoverlay.exe to C:\Program Files\containerd\cni\bin
         and writes the nat network config to C:\Program Files\containerd\cni\conf;
      6. registers containerd as a Windows service and starts it.

    The nat plugin creates the HNS network named "nat" on the first container that asks for it.

.EXAMPLE
    Install-WindowsFeature Containers; Restart-Computer
    .\install-containerd.ps1
#>
param(
    [string] $ContainerdVersion = '2.4.2',
    [string] $NerdctlVersion = '2.4.2',
    [string] $CniVersion = '0.3.3',
    [string] $Subnet = '172.30.0.0/16',
    [string] $Gateway = '172.30.0.1'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ((Get-WindowsFeature -Name Containers).InstallState -ne 'Installed') {
    throw 'Install the Containers feature first: Install-WindowsFeature Containers; Restart-Computer'
}

$root = Join-Path $env:ProgramFiles 'containerd'
$bin = Join-Path $root 'bin'
$cni = Join-Path $root 'cni'
$download = Join-Path $env:TEMP 'containerd-install'
New-Item -ItemType Directory -Force -Path $bin, "$cni\bin", "$cni\conf", $download | Out-Null

function Get-Release([string] $Url, [string] $SumUrl) {
    $file = Join-Path $download (Split-Path $Url -Leaf)
    $sums = Join-Path $download ('sums-' + (Split-Path $SumUrl -Leaf))
    curl.exe -sSfL -o $file $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
    curl.exe -sSfL -o $sums $SumUrl
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $SumUrl" }
    $name = Split-Path $file -Leaf
    $line = Get-Content $sums | Where-Object { $_ -match [regex]::Escape($name) -or $_ -match '^[0-9a-f]{64}$' } | Select-Object -First 1
    $expected = ($line -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw "SHA-256 mismatch for ${name}: expected $expected, got $actual" }
    Write-Host "  $name  sha256 ok"
    $file
}

'containerd'
$gh = 'https://github.com/containerd/containerd/releases/download'
$f = "containerd-$ContainerdVersion-windows-amd64.tar.gz"
$file = Get-Release "$gh/v$ContainerdVersion/$f" "$gh/v$ContainerdVersion/$f.sha256sum"
tar.exe -xzf $file -C $root          # the archive holds bin\*.exe
if ($LASTEXITCODE -ne 0) { throw "tar failed on $file" }

'nerdctl'
$gh = 'https://github.com/containerd/nerdctl/releases/download'
$f = "nerdctl-$NerdctlVersion-windows-amd64.tar.gz"
$file = Get-Release "$gh/v$NerdctlVersion/$f" "$gh/v$NerdctlVersion/SHA256SUMS"
tar.exe -xzf $file -C $bin
if ($LASTEXITCODE -ne 0) { throw "tar failed on $file" }

'CNI plugins'
$gh = 'https://github.com/microsoft/windows-container-networking/releases/download'
$f = "windows-container-networking-cni-amd64-v$CniVersion.zip"
$file = Get-Release "$gh/v$CniVersion/$f" "$gh/v$CniVersion/$f.sha256"
tar.exe -xf $file -C "$cni\bin"
if ($LASTEXITCODE -ne 0) { throw "tar failed on $file" }

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (($machinePath -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$bin", 'Machine')
}
$env:Path = "$env:Path;$bin"

'config.toml'
& "$bin\containerd.exe" config default | Set-Content (Join-Path $root 'config.toml') -Encoding ascii

'nat network config'
$conflist = [ordered]@{
    cniVersion = '0.3.0'
    name       = 'nat'
    plugins    = @(
        [ordered]@{
            type         = 'nat'
            master       = 'Ethernet'
            ipam         = [ordered]@{ subnet = $Subnet; routes = @(@{ gateway = $Gateway }) }
            capabilities = [ordered]@{ portMappings = $true; dns = $true }
        }
    )
}
$conflist | ConvertTo-Json -Depth 6 | Set-Content "$cni\conf\0-containerd-nat.conflist" -Encoding ascii

'containerd service'
if (-not (Get-Service containerd -ErrorAction SilentlyContinue)) {
    & "$bin\containerd.exe" --register-service
    if ($LASTEXITCODE -ne 0) { throw 'containerd --register-service failed' }
}
Start-Service containerd

Remove-Item $download -Recurse -Force
& "$bin\ctr.exe" version
