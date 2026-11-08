<#
.SYNOPSIS
    Installs CoreDNS as the DNS server for containers on the nat network.

.DESCRIPTION
    Part 2 of "Windows containers by hand". The script:

      1. downloads CoreDNS for Windows from GitHub and checks its SHA-256 sum;
      2. writes C:\coredns\Corefile: CoreDNS listens only on the gateway address of the
         nat network, answers with the names from the hosts file that name-ipam keeps,
         and forwards everything else to the DNS server of the host;
      3. allows DNS (UDP and TCP 53) to the gateway address from the container subnet;
      4. registers the scheduled task CoreDNS that runs CoreDNS as SYSTEM. The task has
         no trigger: the gateway address appears only when the first container creates
         the nat network, so name-ipam starts the task on ADD ("dnsTask" in its config);
      5. sets "dnsTask" in C:\ProgramData\name-ipam\config.json and adds the DNS server
         to the nat network config, so new containers use it.
#>
param(
    [string] $Version = '1.15.0',
    [string] $Gateway = '172.30.0.1',
    [string] $Subnet = '172.30.0.0/16',
    [string] $HostsFile = 'C:\ProgramData\name-ipam\hosts',
    [string] $Upstream = (Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { $_.ServerAddresses -and $_.InterfaceAlias -notlike 'vEthernet*' } |
        Select-Object -First 1).ServerAddresses[0]
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$dir = 'C:\coredns'
New-Item -ItemType Directory $dir -Force | Out-Null

# Windows PowerShell 5.1 indents ConvertTo-Json output unevenly; re-indent it by four spaces.
function Format-Json([string] $Json) {
    $level = 0
    $lines = foreach ($l in $Json -split "`r?`n") {
        $line = $l.Trim() -replace '^("[^"]*"):\s+', '$1: '
        if ($line -match '^[\]\}]') { $level-- }
        ('    ' * $level) + $line
        if ($line -match '[\{\[]$') { $level++ }
    }
    ($lines -join "`r`n") + "`r`n"
}

'CoreDNS'
$zip = "coredns_${Version}_windows_amd64.zip"
$url = "https://github.com/coredns/coredns/releases/download/v$Version"
curl.exe -sSfL -o "$env:TEMP\$zip" "$url/$zip"
$expected = ((curl.exe -sSfL "$url/$zip.sha256") -split '\s+')[0].ToLower()
$actual = (Get-FileHash "$env:TEMP\$zip" -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) { throw "SHA-256 mismatch: expected $expected, got $actual" }
"  $zip  sha256 ok"
Expand-Archive "$env:TEMP\$zip" -DestinationPath $dir -Force
Remove-Item "$env:TEMP\$zip"

'Corefile'
@"
. {
    bind $Gateway
    hosts $HostsFile {
        ttl 5
        reload 1s
        fallthrough
    }
    forward . $Upstream
    errors
}
"@ | Set-Content "$dir\Corefile" -Encoding ascii

'Firewall'
foreach ($proto in 'UDP', 'TCP') {
    $name = "CoreDNS for containers ($proto)"
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol $proto -LocalPort 53 `
        -LocalAddress $Gateway -RemoteAddress $Subnet -Action Allow | Out-Null
}

'Scheduled task'
$action = New-ScheduledTaskAction -Execute "$dir\coredns.exe" -Argument "-conf $dir\Corefile" -WorkingDirectory $dir
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName CoreDNS -Action $action -Settings $settings `
    -User SYSTEM -RunLevel Highest -Force | Out-Null

'name-ipam config'
$ipamConfig = 'C:\ProgramData\name-ipam\config.json'
$c = [IO.File]::ReadAllText($ipamConfig) | ConvertFrom-Json
$c | Add-Member -NotePropertyName dnsTask -NotePropertyValue 'CoreDNS' -Force
[IO.File]::WriteAllText($ipamConfig, (Format-Json ($c | ConvertTo-Json -Depth 4)))

'nat network config'
$conflist = "$env:ProgramFiles\containerd\cni\conf\0-containerd-nat.conflist"
$cfg = [IO.File]::ReadAllText($conflist) | ConvertFrom-Json
$cfg.plugins[0] | Add-Member -NotePropertyName dns -NotePropertyValue ([ordered]@{ nameservers = @($Gateway) }) -Force
[IO.File]::WriteAllText($conflist, (Format-Json ($cfg | ConvertTo-Json -Depth 6)))
