@echo off
echo Hello from a HostProcess image
echo user: %USERNAME%, computer: %COMPUTERNAME%
echo files: %CONTAINER_SANDBOX_MOUNT_POINT%
dir /b %CONTAINER_SANDBOX_MOUNT_POINT%app
