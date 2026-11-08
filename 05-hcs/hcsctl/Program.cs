// hcsctl creates and runs Windows containers straight through the Host Compute Service:
// computecore.dll for compute systems and processes, computenetwork.dll for HNS endpoints.
// There is no containerd, no shim and no OCI spec: the caller writes the HCS JSON documents.
//
//   hcsctl net <namespace-guid> <network-name> <ip>/<prefix> <gateway> <dns> [host:container ...]
//       creates an HNS endpoint in the network, with port mappings, and a namespace holding it
//   hcsctl net-rm <namespace-guid>
//       deletes the namespace and its endpoints
//   hcsctl create <id> <system.json>
//       creates and starts a compute system from an HCS document; it outlives hcsctl
//   hcsctl exec [-d] <id> <process.json>
//       starts a process in the compute system; without -d copies its stdout and stderr
//       and returns its exit code, with -d leaves it running
//   hcsctl ls
//       lists compute systems
//   hcsctl props <id>
//       prints the properties of a compute system
//   hcsctl rm <id>
//       terminates the compute system
//   hcsctl layer-id <folder>
//       prints the layer GUID HCS expects for a layer folder

using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Hcsctl;

try
{
    return Cli.Run(args);
}
catch (Exception e)
{
    Console.Error.WriteLine($"hcsctl: {e.Message}");
    return 1;
}

namespace Hcsctl
{
    static class Cli
    {
        public static int Run(string[] args)
        {
            switch (args)
            {
                case ["create", var id, var file]:
                    Hcs.Create(id, File.ReadAllText(file));
                    Console.WriteLine(id);
                    return 0;
                case ["exec", "-d", var id, var file]:
                    return Hcs.Exec(id, File.ReadAllText(file), detach: true);
                case ["exec", var id, var file]:
                    return Hcs.Exec(id, File.ReadAllText(file), detach: false);
                case ["ls"]:
                    Console.WriteLine(Pretty(Hcs.Enumerate()));
                    return 0;
                case ["props", var id]:
                    Console.WriteLine(Pretty(Hcs.Properties(id)));
                    return 0;
                case ["rm", var id]:
                    Hcs.Terminate(id);
                    return 0;
                case ["net", var ns, var network, var ip, var gateway, var dns, .. var ports]:
                {
                    using var e = JsonDocument.Parse(Hcn.CreateEndpoint(Guid.Parse(ns), network, ip, gateway, dns, ports));
                    var r = e.RootElement;
                    Console.WriteLine($"endpoint {r.GetProperty("ID").GetString()}");
                    Console.WriteLine($"address  {r.GetProperty("IpConfigurations")[0].GetProperty("IpAddress").GetString()}");
                    Console.WriteLine($"mac      {r.GetProperty("MacAddress").GetString()}");
                    Console.WriteLine($"ports    {string.Join(", ", ports)}");
                    return 0;
                }
                case ["net-rm", var ns]:
                    Hcn.DeleteNamespace(Guid.Parse(ns));
                    return 0;
                case ["layer-id", var folder]:
                    Console.WriteLine(Hcs.LayerId(folder));
                    return 0;
                default:
                    Console.Error.WriteLine("usage: hcsctl net|net-rm|create|exec|ls|props|rm|layer-id ... (see Program.cs)");
                    return 2;
            }
        }

        static string Pretty(string json)
        {
            using var doc = JsonDocument.Parse(json);
            using var ms = new MemoryStream();
            using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true, IndentSize = 4 }))
                doc.WriteTo(w);
            return System.Text.Encoding.UTF8.GetString(ms.ToArray());
        }
    }

    /// <summary>Compute systems and processes: computecore.dll.</summary>
    static partial class Hcs
    {
        const uint Infinite = 0xFFFFFFFF;
        const uint GenericAll = 0x10000000;

        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInformation
        {
            public uint ProcessId;
            public uint Reserved;
            public IntPtr StdInput;
            public IntPtr StdOutput;
            public IntPtr StdError;
        }

        [LibraryImport("computecore.dll")]
        private static partial IntPtr HcsCreateOperation(IntPtr context, IntPtr callback);

        [LibraryImport("computecore.dll")]
        private static partial void HcsCloseOperation(IntPtr operation);

        [LibraryImport("computecore.dll")]
        private static partial int HcsWaitForOperationResult(IntPtr operation, uint timeoutMs, out IntPtr resultDocument);

        [LibraryImport("computecore.dll")]
        private static partial int HcsWaitForOperationResultAndProcessInfo(IntPtr operation, uint timeoutMs, out ProcessInformation info, out IntPtr resultDocument);

        [LibraryImport("computecore.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcsCreateComputeSystem(string id, string configuration, IntPtr operation, IntPtr securityDescriptor, out IntPtr computeSystem);

        [LibraryImport("computecore.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcsOpenComputeSystem(string id, uint requestedAccess, out IntPtr computeSystem);

        [LibraryImport("computecore.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcsStartComputeSystem(IntPtr computeSystem, IntPtr operation, string? options);

        [LibraryImport("computecore.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcsTerminateComputeSystem(IntPtr computeSystem, IntPtr operation, string? options);

        [LibraryImport("computecore.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcsGetComputeSystemProperties(IntPtr computeSystem, IntPtr operation, string? propertyQuery);

        [LibraryImport("computecore.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcsEnumerateComputeSystems(string? query, IntPtr operation);

        [LibraryImport("computecore.dll")]
        private static partial void HcsCloseComputeSystem(IntPtr computeSystem);

        [LibraryImport("computecore.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcsCreateProcess(IntPtr computeSystem, string processParameters, IntPtr operation, IntPtr securityDescriptor, out IntPtr process);

        [LibraryImport("computecore.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcsGetProcessProperties(IntPtr process, IntPtr operation, string? propertyQuery);

        [LibraryImport("computecore.dll")]
        private static partial void HcsCloseProcess(IntPtr process);

        // The layer GUID hcsshim and HCS derive from the name of a layer folder.
        [LibraryImport("vmcompute.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int NameToGuid(string name, out Guid guid);

        [LibraryImport("kernel32.dll")]
        private static partial IntPtr LocalFree(IntPtr mem);

        /// <summary>
        /// Every HCS call is asynchronous: it takes an operation, and the result document
        /// (or the error document) comes from waiting on that operation.
        /// </summary>
        static string Wait(IntPtr op, int hr, string what)
        {
            if (hr < 0) throw new InvalidOperationException($"{what}: 0x{hr:X8}");
            hr = HcsWaitForOperationResult(op, Infinite, out var doc);
            var result = TakeString(doc);
            if (hr < 0) throw new InvalidOperationException($"{what}: 0x{hr:X8} {result}");
            return result;
        }

        static string TakeString(IntPtr p)
        {
            if (p == IntPtr.Zero) return "";
            var s = Marshal.PtrToStringUni(p) ?? "";
            LocalFree(p);
            return s;
        }

        public static void Create(string id, string document)
        {
            var op = HcsCreateOperation(IntPtr.Zero, IntPtr.Zero);
            try
            {
                Wait(op, HcsCreateComputeSystem(id, document, op, IntPtr.Zero, out var system), "HcsCreateComputeSystem");
                try
                {
                    Wait(op, HcsStartComputeSystem(system, op, null), "HcsStartComputeSystem");
                }
                finally
                {
                    HcsCloseComputeSystem(system);
                }
            }
            finally
            {
                HcsCloseOperation(op);
            }
        }

        static IntPtr Open(string id)
        {
            var hr = HcsOpenComputeSystem(id, GenericAll, out var system);
            if (hr < 0) throw new InvalidOperationException($"HcsOpenComputeSystem {id}: 0x{hr:X8}");
            return system;
        }

        public static int Exec(string id, string parameters, bool detach)
        {
            var system = Open(id);
            var op = HcsCreateOperation(IntPtr.Zero, IntPtr.Zero);
            try
            {
                var hr = HcsCreateProcess(system, parameters, op, IntPtr.Zero, out var process);
                if (hr < 0) throw new InvalidOperationException($"HcsCreateProcess: 0x{hr:X8}");
                hr = HcsWaitForOperationResultAndProcessInfo(op, Infinite, out var info, out var doc);
                var result = TakeString(doc);
                if (hr < 0) throw new InvalidOperationException($"HcsCreateProcess: 0x{hr:X8} {result}");
                try
                {
                    if (detach)
                    {
                        Console.WriteLine($"process {info.ProcessId}");
                        return 0;
                    }
                    // The pipes HCS created for the process: copy them to ours until the process closes them.
                    // Only the pipes the parameters asked for exist; the other handles are not valid.
                    using var p = JsonDocument.Parse(parameters);
                    bool Wants(string pipe) => p.RootElement.TryGetProperty(pipe, out var v) && v.ValueKind == JsonValueKind.True;
                    var copies = new[]
                    {
                        Wants("CreateStdOutPipe") ? Copy(info.StdOutput, Console.OpenStandardOutput()) : Task.CompletedTask,
                        Wants("CreateStdErrPipe") ? Copy(info.StdError, Console.OpenStandardError()) : Task.CompletedTask,
                    };
                    Task.WaitAll(copies);
                    return ExitCode(process);
                }
                finally
                {
                    HcsCloseProcess(process);
                }
            }
            finally
            {
                HcsCloseOperation(op);
                HcsCloseComputeSystem(system);
            }
        }

        static Task Copy(IntPtr handle, Stream to)
        {
            // A pipe the process parameters did not ask for comes back as a null or invalid handle.
            if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return Task.CompletedTask;
            return Task.Run(() =>
            {
                using var from = new FileStream(new SafeFileHandle(handle, ownsHandle: true), FileAccess.Read, 1);
                from.CopyTo(to);
                to.Flush();
            });
        }

        /// <summary>Waits until HCS reports the process as exited and returns its exit code.</summary>
        static int ExitCode(IntPtr process)
        {
            for (; ; )
            {
                var op = HcsCreateOperation(IntPtr.Zero, IntPtr.Zero);
                try
                {
                    var props = Wait(op, HcsGetProcessProperties(process, op, null), "HcsGetProcessProperties");
                    using var doc = JsonDocument.Parse(props);
                    if (doc.RootElement.TryGetProperty("Exited", out var exited) && exited.GetBoolean())
                        return doc.RootElement.TryGetProperty("ExitCode", out var code) ? (int)code.GetUInt32() : 0;
                }
                finally
                {
                    HcsCloseOperation(op);
                }
                Thread.Sleep(100);
            }
        }

        public static string Enumerate()
        {
            var op = HcsCreateOperation(IntPtr.Zero, IntPtr.Zero);
            try
            {
                return Wait(op, HcsEnumerateComputeSystems(null, op), "HcsEnumerateComputeSystems");
            }
            finally
            {
                HcsCloseOperation(op);
            }
        }

        public static string Properties(string id)
        {
            var system = Open(id);
            var op = HcsCreateOperation(IntPtr.Zero, IntPtr.Zero);
            try
            {
                return Wait(op, HcsGetComputeSystemProperties(system, op, null), "HcsGetComputeSystemProperties");
            }
            finally
            {
                HcsCloseOperation(op);
                HcsCloseComputeSystem(system);
            }
        }

        public static void Terminate(string id)
        {
            var system = Open(id);
            var op = HcsCreateOperation(IntPtr.Zero, IntPtr.Zero);
            try
            {
                Wait(op, HcsTerminateComputeSystem(system, op, null), "HcsTerminateComputeSystem");
            }
            finally
            {
                HcsCloseOperation(op);
                HcsCloseComputeSystem(system);
            }
        }

        public static Guid LayerId(string folder)
        {
            var hr = NameToGuid(Path.GetFileName(Path.TrimEndingDirectorySeparator(folder)), out var guid);
            if (hr < 0) throw new InvalidOperationException($"NameToGuid: 0x{hr:X8}");
            return guid;
        }
    }

    /// <summary>HNS networks, endpoints and namespaces: computenetwork.dll.</summary>
    static partial class Hcn
    {
        [LibraryImport("computenetwork.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcnEnumerateNetworks(string query, out IntPtr networks, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll")]
        private static partial int HcnOpenNetwork(in Guid id, out IntPtr network, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll")]
        private static partial int HcnCloseNetwork(IntPtr network);

        [LibraryImport("computenetwork.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcnCreateEndpoint(IntPtr network, in Guid id, string settings, out IntPtr endpoint, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcnQueryEndpointProperties(IntPtr endpoint, string query, out IntPtr properties, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll")]
        private static partial int HcnCloseEndpoint(IntPtr endpoint);

        [LibraryImport("computenetwork.dll")]
        private static partial int HcnDeleteEndpoint(in Guid id, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcnCreateNamespace(in Guid id, string settings, out IntPtr ns, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll")]
        private static partial int HcnOpenNamespace(in Guid id, out IntPtr ns, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcnModifyNamespace(IntPtr ns, string settings, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll", StringMarshalling = StringMarshalling.Utf16)]
        private static partial int HcnQueryNamespaceProperties(IntPtr ns, string query, out IntPtr properties, out IntPtr errorRecord);

        [LibraryImport("computenetwork.dll")]
        private static partial int HcnCloseNamespace(IntPtr ns);

        [LibraryImport("computenetwork.dll")]
        private static partial int HcnDeleteNamespace(in Guid id, out IntPtr errorRecord);

        [LibraryImport("ole32.dll")]
        private static partial void CoTaskMemFree(IntPtr mem);

        const string Schema = """{"Major": 2, "Minor": 0}""";

        static string TakeString(IntPtr p)
        {
            if (p == IntPtr.Zero) return "";
            var s = Marshal.PtrToStringUni(p) ?? "";
            CoTaskMemFree(p);
            return s;
        }

        static void Check(int hr, IntPtr errorRecord, string what)
        {
            var error = TakeString(errorRecord);
            if (hr < 0) throw new InvalidOperationException($"{what}: 0x{hr:X8} {error}");
        }

        static Guid NetworkByName(string name)
        {
            var query = $$"""{"SchemaVersion": {{Schema}}, "Filter": "{\"Name\": \"{{name}}\"}"}""";
            var hr = HcnEnumerateNetworks(query, out var list, out var error);
            Check(hr, error, "HcnEnumerateNetworks");
            using var doc = JsonDocument.Parse(TakeString(list));
            var ids = doc.RootElement.EnumerateArray().Select(e => e.GetString()!).ToList();
            if (ids.Count == 0) throw new InvalidOperationException($"no HNS network named {name}; start one container with the nat CNI plugin first");
            return Guid.Parse(ids[0]);
        }

        /// <summary>
        /// Creates an endpoint with a fixed address in the network and a namespace holding it;
        /// the container document refers to the namespace by its GUID.
        /// </summary>
        public static string CreateEndpoint(Guid nsId, string networkName, string ipPrefix, string gateway, string dns, string[] ports)
        {
            var networkId = NetworkByName(networkName);
            var hr = HcnOpenNetwork(networkId, out var network, out var error);
            Check(hr, error, "HcnOpenNetwork");
            var endpointId = Guid.NewGuid();
            var (ip, prefix) = ipPrefix.Split('/') is [var a, var b] ? (a, b) : throw new ArgumentException("ip must be <address>/<prefix>");
            var policies = string.Join(", ", ports.Select(p => p.Split(':') is [var h, var c]
                ? $$$"""{"Type": "PortMapping", "Settings": {"Protocol": 6, "ExternalPort": {{{h}}}, "InternalPort": {{{c}}}}}"""
                : throw new ArgumentException($"port must be <host>:<container>, got {p}")));
            var settings = $$"""
                {
                    "SchemaVersion": {{Schema}},
                    "Owner": "hcsctl",
                    "HostComputeNetwork": "{{networkId}}",
                    "IpConfigurations": [{"IpAddress": "{{ip}}", "PrefixLength": {{prefix}}}],
                    "Routes": [{"NextHop": "{{gateway}}", "DestinationPrefix": "0.0.0.0/0"}],
                    "Dns": {"ServerList": ["{{dns}}"]},
                    "Policies": [{{policies}}]
                }
                """;
            string props;
            try
            {
                hr = HcnCreateEndpoint(network, endpointId, settings, out var endpoint, out error);
                Check(hr, error, "HcnCreateEndpoint");
                hr = HcnQueryEndpointProperties(endpoint, $$"""{"SchemaVersion": {{Schema}}}""", out var p, out error);
                Check(hr, error, "HcnQueryEndpointProperties");
                props = TakeString(p);
                HcnCloseEndpoint(endpoint);
            }
            finally
            {
                HcnCloseNetwork(network);
            }

            hr = HcnCreateNamespace(nsId, $$"""{"SchemaVersion": {{Schema}}, "Type": "Host"}""", out var ns, out error);
            Check(hr, error, "HcnCreateNamespace");
            try
            {
                hr = HcnModifyNamespace(ns, $$$"""{"ResourceType": "Endpoint", "RequestType": "Add", "Settings": {"EndpointId": "{{{endpointId}}}"}}""", out error);
                Check(hr, error, "HcnModifyNamespace");
            }
            finally
            {
                HcnCloseNamespace(ns);
            }
            return props;
        }

        public static void DeleteNamespace(Guid nsId)
        {
            var hr = HcnOpenNamespace(nsId, out var ns, out var error);
            Check(hr, error, "HcnOpenNamespace");
            string props;
            try
            {
                hr = HcnQueryNamespaceProperties(ns, $$"""{"SchemaVersion": {{Schema}}}""", out var p, out error);
                Check(hr, error, "HcnQueryNamespaceProperties");
                props = TakeString(p);
            }
            finally
            {
                HcnCloseNamespace(ns);
            }
            hr = HcnDeleteNamespace(nsId, out error);
            Check(hr, error, "HcnDeleteNamespace");
            using var doc = JsonDocument.Parse(props);
            if (!doc.RootElement.TryGetProperty("Resources", out var resources)) return;
            foreach (var r in resources.EnumerateArray())
            {
                if (r.GetProperty("Type").GetString() != "Endpoint") continue;
                var id = Guid.Parse(r.GetProperty("Data").GetProperty("Id").GetString()!);
                hr = HcnDeleteEndpoint(id, out error);
                Check(hr, error, "HcnDeleteEndpoint");
            }
        }
    }
}
