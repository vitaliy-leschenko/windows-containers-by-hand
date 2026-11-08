# What a container sees of its machine: run it inside a Server Core container, with process
# and with Hyper-V isolation, to compare (part 6 of "Windows containers by hand"):
#
#   nerdctl run --rm -v C:\lab\probe:C:\probe:ro mcr.microsoft.com/windows/servercore:ltsc2025 powershell -NoProfile -File C:\probe\probe.ps1
#   nerdctl run --rm --isolation hyperv -v C:\lab\probe:C:\probe:ro mcr.microsoft.com/windows/servercore:ltsc2025 powershell -NoProfile -File C:\probe\probe.ps1
$cs = Get-CimInstance Win32_ComputerSystem
"Model: $($cs.Model); CPUs: $($cs.NumberOfLogicalProcessors); memory: $([int]($cs.TotalPhysicalMemory / 1MB)) MB"
"Kernel: $((Get-Item C:\Windows\System32\ntoskrnl.exe).VersionInfo.ProductVersion)"
