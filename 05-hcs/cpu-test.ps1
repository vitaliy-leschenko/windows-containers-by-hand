<#
.SYNOPSIS
    Checks the processor limit of a compute system created straight through HCS.

.DESCRIPTION
    Creates a Nano Server container with hcsctl, with or without "Processor": {"Count": N},
    starts four endless cmd loops in it and adds up the processor time of the container's
    processes over ten seconds. Each loop wants a whole core.

.EXAMPLE
    .\cpu-test.ps1
    .\cpu-test.ps1 -Cpus 1
#>
param(
    [int] $Cpus = 0,
    [string] $Base = 'C:\images\nanoserver\layers\9a4c0752c6bda5fc00f886a9acf0c0afed0750082f7999c331df978fb9f97d2a',
    [string] $Hcsctl = 'C:\hcs\hcsctl.exe',
    [string] $Wclayer = 'C:\hcs\wclayer.exe'
)
$ErrorActionPreference = 'Stop'
$id = "cpu-test-$PID"
$scratch = Join-Path $env:TEMP $id
$work = New-Item -ItemType Directory (Join-Path $env:TEMP "$id-docs")

& $Wclayer create -l $Base $scratch
$volume = (& $Wclayer mount -l $Base $scratch | Out-String).Trim()
$container = [ordered]@{
    GuestOs = @{ HostName = 'cpu-test' }
    Storage =[ordered]@{ Layers = @([ordered]@{ Id = (& $Hcsctl layer-id $Base); Path = $Base }); Path = $volume }
}
if ($Cpus) { $container.Processor = @{ Count = $Cpus } }
[ordered]@{
    SchemaVersion = [ordered]@{ Major = 2; Minor = 1 }
    Owner = 'hcsctl'
    ShouldTerminateOnLastHandleClosed = $false
    Container = $container
} | ConvertTo-Json -Depth 6 | Set-Content "$work\system.json" -Encoding ascii
'{ "CommandLine": "cmd /c for /l %i in (0,0,1) do rem" }' | Set-Content "$work\loop.json" -Encoding ascii

try {
    & $Hcsctl create $id "$work\system.json" | Out-Null
    1..4 | ForEach-Object { & $Hcsctl exec -d $id "$work\loop.json" | Out-Null }
    $session = (& $Hcsctl props $id | ConvertFrom-Json).ServiceSessionId
    function Get-CpuSeconds { (Get-Process cmd | Where-Object SessionId -eq $session | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum }
    Start-Sleep 2
    $before = Get-CpuSeconds
    Start-Sleep 10
    $used = ((Get-CpuSeconds) - $before) / 10
    $limit = if ($Cpus) { "Processor.Count $Cpus" } else { 'no limit' }
    '{0}; session {1}; CPU used: {2:N2} of {3} cores' -f $limit, $session, $used, [Environment]::ProcessorCount
}
finally {
    & $Hcsctl rm $id
    & $Wclayer unmount $scratch
    & $Wclayer remove $scratch
    Remove-Item $work -Recurse
}
