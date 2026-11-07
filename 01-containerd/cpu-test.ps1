<#
.SYNOPSIS
    Measures how much CPU a process-isolated container gets, with or without a limit.

.DESCRIPTION
    Starts a Server Core container in which four PowerShell processes spin in an empty loop
    (each wants a whole core), finds the container's processes on the host by the session
    number that hcsdiag reports, sums their CPU time over ten seconds and prints how many
    cores that is. The container is removed at the end.

.EXAMPLE
    .\cpu-test.ps1
    .\cpu-test.ps1 -Cpus 1
#>
param(
    [string] $Cpus,
    [string] $Image = 'mcr.microsoft.com/windows/servercore:ltsc2025'
)

$burn = "1..4 | ForEach-Object { Start-Process powershell -ArgumentList '-NoProfile','-Command','while (`$true) {}' }; Start-Sleep 600"
$limit = @()
if ($Cpus) { $limit = @('--cpus', $Cpus) }

$id = nerdctl run -d @limit $Image powershell -NoProfile -Command $burn 2>$null
Start-Sleep 5

# hcsdiag list prints the container id, and on the next line its type, state, owner and session
$hcs = (hcsdiag list) -join "`n"
$session = [int][regex]::Match($hcs, "$id\s*\n[^\n]*,\s*(\d+)\s*(\n|$)").Groups[1].Value

function Get-CpuTicks {
    (Get-Process -Name powershell | Where-Object SessionId -eq $session |
        ForEach-Object { $_.TotalProcessorTime.Ticks } | Measure-Object -Sum).Sum
}

$t0 = Get-CpuTicks
$sw = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep 10
$t1 = Get-CpuTicks
$cores = ($t1 - $t0) / 1e4 / $sw.Elapsed.TotalMilliseconds   # ticks are 100 ns
$count = @(Get-Process -Name powershell | Where-Object SessionId -eq $session).Count

'limit: {0}; session {1}; {2} powershell processes; CPU used: {3:N2} of {4} cores' -f `
    $(if ($Cpus) { "--cpus $Cpus" } else { 'none' }), $session, $count, $cores, [Environment]::ProcessorCount

nerdctl rm -f $id 2>$null | Out-Null
