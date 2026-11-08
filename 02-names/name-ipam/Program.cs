// name-ipam is a CNI IPAM plugin for Windows containers started by nerdctl or ctr.
//
// It gives a container a fixed address when its name is listed in "addresses",
// otherwise the first free address of the range, and keeps a hosts file with the
// names and addresses of all running containers for a DNS server such as CoreDNS.
//
// The container name is the nerdctl/name label that nerdctl puts on the container;
// the plugin reads it from containerd with ctr. Containers without the label
// (for example started by ctr) are named by the first 12 characters of their id.
//
// The network config only names the plugin: "ipam": {"type": "name-ipam", ...}.
// The Microsoft nat plugin passes on just the ipam fields it knows itself, so
// name-ipam keeps its own settings in C:\ProgramData\name-ipam\config.json:
//
//     {
//         "subnet": "172.30.0.0/16",
//         "gateway": "172.30.0.1",
//         "rangeStart": "172.30.1.1",
//         "rangeEnd": "172.30.1.254",
//         "addresses": { "web": "172.30.0.10" },
//         "dnsTask": "CoreDNS"
//     }
//
// Next to it the plugin keeps <network name>.json with the leases and the hosts file.
// "dnsTask" is the scheduled task of the DNS server: it binds to the gateway address,
// which exists only after the nat network is created, so the plugin starts the task
// on ADD when it is not running.

using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using NameIpam;

const string DataDir = @"C:\ProgramData\name-ipam";

try
{
    return Plugin.Run(DataDir);
}
catch (Exception e)
{
    // The CNI error format: the runtime shows msg to the user.
    Plugin.WriteJson(w =>
    {
        w.WriteString("cniVersion", "0.3.0");
        w.WriteNumber("code", 100);
        w.WriteString("msg", e.Message);
    });
    return 1;
}

namespace NameIpam
{
    public sealed class IpamConfig
    {
        public string Subnet { get; set; } = "";
        public string Gateway { get; set; } = "";
        public string RangeStart { get; set; } = "";
        public string RangeEnd { get; set; } = "";
        public Dictionary<string, string> Addresses { get; set; } = new();
        public string? DnsTask { get; set; }
    }

    public sealed class NetConfig
    {
        public string? CniVersion { get; set; }
        public string Name { get; set; } = "";
    }

    /// <summary>One running container: its name and address.</summary>
    public sealed class Lease
    {
        public string Name { get; set; } = "";
        public string Ip { get; set; } = "";
    }

    public sealed class ContainerInfo
    {
        public Dictionary<string, string>? Labels { get; set; }
    }

    [JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true)]
    [JsonSerializable(typeof(IpamConfig))]
    [JsonSerializable(typeof(NetConfig))]
    [JsonSerializable(typeof(Dictionary<string, Lease>))]
    internal partial class CamelCaseContext : JsonSerializerContext;

    // ctr prints the container with Go field names: "Labels".
    [JsonSerializable(typeof(ContainerInfo))]
    internal partial class PascalCaseContext : JsonSerializerContext;

    public static class Plugin
    {
        public static int Run(string dataDir)
        {
            var command = Environment.GetEnvironmentVariable("CNI_COMMAND");
            if (command == "VERSION")
            {
                Console.Out.Write("""{"cniVersion":"0.4.0","supportedVersions":["0.3.0","0.3.1","0.4.0"]}""");
                return 0;
            }

            var net = JsonSerializer.Deserialize(Console.In.ReadToEnd(), CamelCaseContext.Default.NetConfig)
                ?? throw new InvalidDataException("empty network config");
            var configPath = Path.Combine(dataDir, "config.json");
            var config = JsonSerializer.Deserialize(File.ReadAllText(configPath), CamelCaseContext.Default.IpamConfig)
                ?? throw new InvalidDataException($"empty {configPath}");
            var id = Environment.GetEnvironmentVariable("CNI_CONTAINERID");
            if (string.IsNullOrEmpty(id)) throw new InvalidOperationException("CNI_CONTAINERID is empty");

            using var _ = Lock(Path.Combine(dataDir, "lock"));

            var statePath = Path.Combine(dataDir, net.Name + ".json");
            var hostsPath = Path.Combine(dataDir, "hosts");
            var leases = File.Exists(statePath)
                ? JsonSerializer.Deserialize(File.ReadAllText(statePath), CamelCaseContext.Default.DictionaryStringLease) ?? new()
                : new Dictionary<string, Lease>();

            switch (command)
            {
                case "ADD":
                    Prune(leases, id);
                    if (!leases.TryGetValue(id, out var lease))
                    {
                        var name = ContainerName(id);
                        lease = new Lease { Name = name, Ip = Pick(config, name, leases) };
                        leases[id] = lease;
                    }
                    Save(statePath, hostsPath, leases);
                    EnsureTask(config.DnsTask);
                    PrintResult(net.CniVersion ?? "0.3.0", config, lease.Ip);
                    return 0;
                case "DEL":
                    leases.Remove(id);
                    Save(statePath, hostsPath, leases);
                    return 0;
                case "CHECK":
                    if (!leases.ContainsKey(id)) throw new InvalidOperationException($"no address for container {id}");
                    return 0;
                default:
                    throw new InvalidOperationException($"unknown CNI_COMMAND \"{command}\"");
            }
        }

        /// <summary>Asks containerd for the nerdctl/name label of the container.</summary>
        static string ContainerName(string id)
        {
            var output = Exec("ctr", "-n", "default", "containers", "info", id);
            if (output != null)
            {
                var info = JsonSerializer.Deserialize(output, PascalCaseContext.Default.ContainerInfo);
                if (info?.Labels?.TryGetValue("nerdctl/name", out var name) == true && name != "") return name;
            }
            return id.Length > 12 ? id[..12] : id;
        }

        /// <summary>
        /// Drops the leases of containers containerd no longer knows: their DEL never came,
        /// for example because the host was rebooted with the containers running.
        /// </summary>
        static void Prune(Dictionary<string, Lease> leases, string current)
        {
            var output = Exec("ctr", "-n", "default", "containers", "ls", "-q");
            if (output == null) return;
            var known = new HashSet<string>(output.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)) { current };
            foreach (var id in leases.Keys.Where(k => !known.Contains(k)).ToList()) leases.Remove(id);
        }

        /// <summary>Returns the fixed address of the name, or the first free address of the range.</summary>
        static string Pick(IpamConfig config, string name, Dictionary<string, Lease> leases)
        {
            var used = leases.Values.ToDictionary(l => l.Ip, l => l.Name);
            if (config.Addresses.TryGetValue(name, out var fixedIp))
            {
                if (used.TryGetValue(fixedIp, out var other))
                    throw new InvalidOperationException($"address {fixedIp} of {name} is used by {other}");
                return fixedIp;
            }
            var reserved = config.Addresses.Values.ToHashSet();
            uint start = ToUInt(config.RangeStart), end = ToUInt(config.RangeEnd);
            if (start == 0 || end < start)
                throw new InvalidDataException("rangeStart and rangeEnd must be IPv4 addresses, start <= end");
            for (var n = start; n <= end; n++)
            {
                var ip = ToIp(n);
                if (!used.ContainsKey(ip) && !reserved.Contains(ip)) return ip;
            }
            throw new InvalidOperationException($"no free address in {config.RangeStart}-{config.RangeEnd}");
        }

        /// <summary>Writes the leases and regenerates the hosts file from them.</summary>
        static void Save(string statePath, string hostsPath, Dictionary<string, Lease> leases)
        {
            WriteFile(statePath, JsonSerializer.Serialize(leases, CamelCaseContext.Default.DictionaryStringLease));
            var hosts = new StringBuilder("# generated by name-ipam, do not edit\r\n127.0.0.1       localhost\r\n");
            foreach (var line in leases.Values.Select(l => $"{l.Ip,-15} {l.Name}").Order(StringComparer.Ordinal))
                hosts.Append(line).Append("\r\n");
            WriteFile(hostsPath, hosts.ToString());
        }

        /// <summary>
        /// Overwrites the file in place, so a bind mount of it keeps working,
        /// and retries while another process (an antivirus scan, a reader) holds it.
        /// </summary>
        static void WriteFile(string path, string text)
        {
            for (var i = 0; ; i++)
            {
                try
                {
                    File.WriteAllText(path, text);
                    return;
                }
                catch (IOException) when (i < 20)
                {
                    Thread.Sleep(100);
                }
            }
        }

        /// <summary>
        /// Starts the scheduled task unless it is already running. Errors are ignored:
        /// a container without DNS is still better than no container.
        /// </summary>
        static void EnsureTask(string? task)
        {
            if (string.IsNullOrEmpty(task)) return;
            var state = Exec("schtasks", "/Query", "/TN", task, "/FO", "CSV", "/NH");
            if (state != null && state.Contains("\"Running\"")) return;
            Exec("schtasks", "/Run", "/TN", task);
        }

        static void PrintResult(string version, IpamConfig config, string ip)
        {
            var prefix = config.Subnet.Split('/') is [_, var bits] ? bits : throw new InvalidDataException($"bad subnet {config.Subnet}");
            WriteJson(w =>
            {
                w.WriteString("cniVersion", version);
                w.WriteStartArray("ips");
                w.WriteStartObject();
                w.WriteString("version", "4");
                w.WriteString("address", $"{ip}/{prefix}");
                w.WriteString("gateway", config.Gateway);
                w.WriteEndObject();
                w.WriteEndArray();
                w.WriteStartArray("routes");
                w.WriteStartObject();
                w.WriteString("dst", "0.0.0.0/0");
                w.WriteString("gw", config.Gateway);
                w.WriteEndObject();
                w.WriteEndArray();
            });
        }

        public static void WriteJson(Action<Utf8JsonWriter> body)
        {
            using var stdout = Console.OpenStandardOutput();
            using var w = new Utf8JsonWriter(stdout);
            w.WriteStartObject();
            body(w);
            w.WriteEndObject();
        }

        /// <summary>
        /// Opens the lock file exclusively; another plugin instance waits for it.
        /// Windows releases the handle when the process exits, even after a crash.
        /// </summary>
        static FileStream Lock(string path)
        {
            for (var i = 0; ; i++)
            {
                try
                {
                    return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                }
                catch (IOException) when (i < 100)
                {
                    Thread.Sleep(100);
                }
            }
        }

        /// <summary>Runs a program and returns its output, or null when it fails.</summary>
        static string? Exec(string file, params string[] args)
        {
            try
            {
                var psi = new ProcessStartInfo(file) { RedirectStandardOutput = true, UseShellExecute = false };
                foreach (var a in args) psi.ArgumentList.Add(a);
                using var p = Process.Start(psi)!;
                var output = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                return p.ExitCode == 0 ? output : null;
            }
            catch (Exception)
            {
                return null;
            }
        }

        static uint ToUInt(string ip) =>
            IPAddress.TryParse(ip, out var a) && a.GetAddressBytes() is { Length: 4 } b
                ? (uint)(b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3])
                : 0;

        static string ToIp(uint n) => new IPAddress([(byte)(n >> 24), (byte)(n >> 16), (byte)(n >> 8), (byte)n]).ToString();
    }
}
