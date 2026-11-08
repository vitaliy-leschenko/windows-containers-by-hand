<#
.SYNOPSIS
    Runs a container from an image pulled by pull-image.ps1, without containerd: wclayer
    prepares the storage, hcsctl creates the HNS endpoint, the compute system and the process.

.DESCRIPTION
    The steps of part 5 of "Windows containers by hand" in one script:

      1. a writable layer on top of the image layers (wclayer create), mounted as a volume
         (wclayer mount);
      2. an HNS endpoint with a fixed address and port mappings in the nat network, inside
         a new HNS namespace (hcsctl net);
      3. the HCS document of the compute system: layers, volume, mapped folders, memory and
         processor limits, namespace (hcsctl create);
      4. the process from the image config: entrypoint and command, working directory, user,
         environment (hcsctl exec -d, or hcsctl exec with its output when -Attach is given).

    What the script created is recorded in C:\containers\<name>\state.json for remove-container.ps1.

.EXAMPLE
    .\run-container.ps1 web2 C:\images\samples -Ip 172.30.0.50 -Publish 8081:8080 -Memory 512 -Cpus 1
#>
param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Image,
    [Parameter(Mandatory)] [string] $Ip,
    [string] $Network = 'nat',
    [int] $PrefixLength = 16,
    [string] $Gateway = '172.30.0.1',
    [string] $Dns = '172.30.0.1',
    [string[]] $Publish = @(),
    [string[]] $Mount = @(),
    [int] $Memory = 0,
    [int] $Cpus = 0,
    # Wait for the process and copy its output instead of leaving it running in the background.
    [switch] $Attach,
    [string] $Root = 'C:\containers',
    [string] $Hcsctl = 'C:\hcs\hcsctl.exe',
    [string] $Wclayer = 'C:\hcs\wclayer.exe'
)
$ErrorActionPreference = 'Stop'

$dir = Join-Path $Root $Name
if (Test-Path $dir) { throw "$dir exists: remove the container first (remove-container.ps1 $Name)" }
New-Item -ItemType Directory $dir | Out-Null
$state = [ordered]@{ Name = $Name; Scratch = Join-Path $dir 'scratch'; Namespace = $null }
$state | ConvertTo-Json | Set-Content (Join-Path $dir 'state.json') -Encoding ascii

# 1. Storage: the writable layer over the image layers, top layer first.
# Windows PowerShell 5.1 returns a JSON array as one object; the second pipeline unrolls it.
$layers = @(Get-Content (Join-Path $Image 'layers.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$l = foreach ($p in $layers) { '-l'; $p }
& $Wclayer create @l $state.Scratch
if ($LASTEXITCODE) { throw 'wclayer create failed' }
$volume = (& $Wclayer mount @l $state.Scratch | Out-String).Trim()
if ($LASTEXITCODE) { throw 'wclayer mount failed' }
Write-Host "volume $volume"

# 2. Network: an endpoint with the address and the port mappings, in a namespace of its own.
$state.Namespace = [guid]::NewGuid().ToString()
$state | ConvertTo-Json | Set-Content (Join-Path $dir 'state.json') -Encoding ascii
& $Hcsctl net $state.Namespace $Network "$Ip/$PrefixLength" $Gateway $Dns @Publish | Out-Null
if ($LASTEXITCODE) { throw 'hcsctl net failed' }
Write-Host "endpoint $Ip in $Network, namespace $($state.Namespace)"

# 3. The compute system.
$container = [ordered]@{
    GuestOs = @{ HostName = $Name }
    Storage = [ordered]@{
        Layers = @(foreach ($p in $layers) { [ordered]@{ Id = (& $Hcsctl layer-id $p); Path = $p } })
        Path = $volume
    }
    Networking = [ordered]@{ AllowUnqualifiedDnsQuery = $true; Namespace = $state.Namespace }
}
if ($Mount) {
    $container.MappedDirectories = @(foreach ($m in $Mount) {
        # host:container[:ro]; both are paths with a drive letter, so split after it.
        if ($m -notmatch '^(?<h>[A-Za-z]:\\[^:]*):(?<c>[A-Za-z]:\\[^:]*)(?<ro>:ro)?$') { throw "mount must be C:\host:C:\container[:ro], got $m" }
        [ordered]@{ HostPath = $Matches.h; ContainerPath = $Matches.c; ReadOnly = [bool]$Matches.ro }
    })
}
if ($Memory) { $container.Memory = @{ SizeInMB = $Memory } }
if ($Cpus) { $container.Processor = @{ Count = $Cpus } }
$doc = [ordered]@{
    SchemaVersion = [ordered]@{ Major = 2; Minor = 1 }
    Owner = 'hcsctl'
    ShouldTerminateOnLastHandleClosed = $false
    Container = $container
}
$doc | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'system.json') -Encoding ascii
& $Hcsctl create $Name (Join-Path $dir 'system.json') | Out-Null
if ($LASTEXITCODE) { throw 'hcsctl create failed' }
Write-Host "compute system $Name"

# 4. The process the image describes.
$config = (Get-Content (Join-Path $Image 'image.json') -Raw | ConvertFrom-Json).config
$environment = [ordered]@{}
foreach ($e in @($config.Env)) { if ($e) { $k, $v = $e -split '=', 2; $environment[$k] = $v } }
$process = [ordered]@{
    CommandLine = (@($config.Entrypoint) + @($config.Cmd) | Where-Object { $_ }) -join ' '
    WorkingDirectory = if ($config.WorkingDir) { $config.WorkingDir } else { 'C:\' }
    User = if ($config.User) { $config.User } else { 'ContainerUser' }
    Environment = $environment
}
if ($Attach) { $process.CreateStdOutPipe = $true; $process.CreateStdErrPipe = $true }
$process | ConvertTo-Json | Set-Content (Join-Path $dir 'process.json') -Encoding ascii
if ($Attach) {
    & $Hcsctl exec $Name (Join-Path $dir 'process.json')
    Write-Host "exit code $LASTEXITCODE"
} else {
    & $Hcsctl exec -d $Name (Join-Path $dir 'process.json')
    if ($LASTEXITCODE) { throw 'hcsctl exec failed' }
}
