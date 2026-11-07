# Windows containers by hand

Examples for a blog series on [vitaliy.org](https://www.vitaliy.org) about running Windows
containers without Docker, going one layer down at a time:

1. containerd without Kubernetes: a manual install, `ctr`, the `nat` CNI plugin, nerdctl.
2. What is inside a running Windows container: the server silo, `hcsdiag`, image layers on disk,
   `sandbox.vhdx`, the `wcifs` and `bindflt` filters.
3. Below containerd: `runhcs.exe`, an OCI bundle and `config.json` written by hand, `wclayer`.
4. A container without a runtime: a compute system through the HCS API and networking through HNS.
5. Hyper-V isolation from the inside: the utility VM.
6. An image without Docker: a layer from a folder, a manifest and an index with `os.version`.

Each folder holds the examples of one part. Everything here has been run on the lab described
below before it was committed.

## Lab

- Windows Server 2025 Datacenter, Server Core (build 26100), a Hyper-V VM with nested
  virtualization so that Hyper-V isolation works inside it.
- Images from `mcr.microsoft.com/windows/nanoserver` and `servercore`, tag `ltsc2025`.

The examples change system state (the Containers feature, HNS networks, compute systems).
Run them on a disposable VM, not on a workstation with Docker Desktop or WSL you rely on.

## License

[MIT](LICENSE)
