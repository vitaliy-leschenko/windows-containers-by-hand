<#
.SYNOPSIS
    Removes a container created by run-container.ps1: the compute system, the HNS namespace
    with its endpoint and the writable layer.

.EXAMPLE
    .\remove-container.ps1 web2
#>
param(
    [Parameter(Mandatory)] [string] $Name,
    [string] $Root = 'C:\containers',
    [string] $Hcsctl = 'C:\hcs\hcsctl.exe',
    [string] $Wclayer = 'C:\hcs\wclayer.exe'
)
$dir = Join-Path $Root $Name
$state = Get-Content (Join-Path $dir 'state.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json

# Every step runs even when an earlier one fails, so that a half-created container goes away too.
& $Hcsctl rm $Name
if ($state.Namespace) { & $Hcsctl net-rm $state.Namespace }
if ($state.Scratch -and (Test-Path $state.Scratch)) {
    & $Wclayer unmount $state.Scratch
    & $Wclayer remove $state.Scratch
}
Remove-Item $dir -Recurse -Force
