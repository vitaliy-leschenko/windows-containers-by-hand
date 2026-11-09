# Windows containers by hand

Examples for a blog series on [vitaliy.org](https://www.vitaliy.org) about running Windows
containers without Docker, going one layer down at a time:

1. containerd without Kubernetes: a manual install, `ctr`, the `nat` CNI plugin, nerdctl.
2. Names and addresses: a shared `hosts` file, the `name-ipam` CNI IPAM plugin in C#, CoreDNS.
3. What is inside a running Windows container: the server silo, `hcsdiag`, image layers on disk,
   `sandbox.vhdx`, the `wcifs` and `bindflt` filters.
4. An image without containerd: the registry API, digests and diff_ids, `wclayer`, and what
   containerd hands to the shim.
5. A container without a runtime: `hcsctl`, a small C# tool over `computecore.dll` and
   `computenetwork.dll`, HCS documents written by hand, and a tiny runtime in two scripts.
6. Hyper-V isolation from the inside: the utility VM, its kernel from the image, a 2019 image on 2025.
7. An image without Docker: a layer from a folder with `wclayer export`, an OCI image layout with
   an index per `os.version`, a push with the OCI distribution API to a registry built from source.
8. HostProcess containers: a container without HCS, a job object, `C:\hpc`, the base image of empty
   registry hives, and an image built with `tar` and loaded with `nerdctl load`.

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
