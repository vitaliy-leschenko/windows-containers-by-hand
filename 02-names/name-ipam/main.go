// name-ipam is a CNI IPAM plugin for Windows containers started by nerdctl or ctr.
//
// It gives a container a fixed address when its name is listed in "addresses",
// otherwise the first free address of the range, and keeps a hosts file with the
// names and addresses of all running containers. The hosts file can be mounted
// into containers read-only, or served by a DNS server such as CoreDNS.
//
// The container name is the nerdctl/name label that nerdctl puts on the container;
// the plugin reads it from containerd with ctr. Containers without the label
// (for example started by ctr) are named by the first 12 characters of their id.
//
// The network config only names the plugin: "ipam": {"type": "name-ipam", ...}.
// The Microsoft nat plugin passes on just the ipam fields it knows itself, so
// name-ipam keeps its own settings in C:\ProgramData\name-ipam\config.json:
//
//	{
//	    "subnet": "172.30.0.0/16",
//	    "gateway": "172.30.0.1",
//	    "rangeStart": "172.30.1.1",
//	    "rangeEnd": "172.30.1.254",
//	    "addresses": { "web": "172.30.0.10" }
//	}
//
// Next to it the plugin keeps <network name>.json with the leases and the hosts file.
package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const dataDir = `C:\ProgramData\name-ipam`

type ipamConfig struct {
	Subnet     string            `json:"subnet"`
	Gateway    string            `json:"gateway"`
	RangeStart string            `json:"rangeStart"`
	RangeEnd   string            `json:"rangeEnd"`
	Addresses  map[string]string `json:"addresses"`
}

type netConfig struct {
	CNIVersion string `json:"cniVersion"`
	Name       string `json:"name"`
}

// lease is one running container: its name and address.
type lease struct {
	Name string `json:"name"`
	IP   string `json:"ip"`
}

func main() {
	if err := run(); err != nil {
		// The CNI error format: the runtime shows msg to the user.
		json.NewEncoder(os.Stdout).Encode(map[string]any{"cniVersion": "0.3.0", "code": 100, "msg": err.Error()})
		os.Exit(1)
	}
}

func run() error {
	cmd := os.Getenv("CNI_COMMAND")
	if cmd == "VERSION" {
		fmt.Print(`{"cniVersion":"0.4.0","supportedVersions":["0.3.0","0.3.1","0.4.0"]}`)
		return nil
	}
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	var conf netConfig
	if err := json.Unmarshal(raw, &conf); err != nil {
		return fmt.Errorf("bad network config: %w", err)
	}
	cfgPath := filepath.Join(dataDir, "config.json")
	b, err := os.ReadFile(cfgPath)
	if err != nil {
		return err
	}
	var c ipamConfig
	if err := json.Unmarshal(b, &c); err != nil {
		return fmt.Errorf("bad %s: %w", cfgPath, err)
	}
	id := os.Getenv("CNI_CONTAINERID")
	if id == "" {
		return errors.New("CNI_CONTAINERID is empty")
	}

	unlock, err := lock(filepath.Join(dataDir, "lock"))
	if err != nil {
		return err
	}
	defer unlock()

	statePath := filepath.Join(dataDir, conf.Name+".json")
	hostsPath := filepath.Join(dataDir, "hosts")
	leases := map[string]lease{}
	if b, err := os.ReadFile(statePath); err == nil {
		json.Unmarshal(b, &leases)
	}

	switch cmd {
	case "ADD":
		prune(leases, id)
		l, ok := leases[id]
		if !ok {
			name := containerName(id)
			ip, err := pick(c, name, leases)
			if err != nil {
				return err
			}
			l = lease{Name: name, IP: ip}
			leases[id] = l
		}
		if err := save(statePath, hostsPath, leases); err != nil {
			return err
		}
		return printResult(conf.CNIVersion, c, l.IP)
	case "DEL":
		delete(leases, id)
		return save(statePath, hostsPath, leases)
	case "CHECK":
		if _, ok := leases[id]; !ok {
			return fmt.Errorf("no address for container %s", id)
		}
		return nil
	}
	return fmt.Errorf("unknown CNI_COMMAND %q", cmd)
}

// prune drops the leases of containers containerd no longer knows: their DEL never
// came, for example because the host was rebooted with the containers running.
func prune(leases map[string]lease, current string) {
	out, err := exec.Command("ctr", "-n", "default", "containers", "ls", "-q").Output()
	if err != nil {
		return
	}
	known := map[string]bool{current: true}
	for _, line := range strings.Fields(string(out)) {
		known[line] = true
	}
	for id := range leases {
		if !known[id] {
			delete(leases, id)
		}
	}
}

// containerName asks containerd for the nerdctl/name label of the container.
func containerName(id string) string {
	out, err := exec.Command("ctr", "-n", "default", "containers", "info", id).Output()
	if err == nil {
		var info struct {
			Labels map[string]string `json:"Labels"`
		}
		if json.Unmarshal(out, &info) == nil && info.Labels["nerdctl/name"] != "" {
			return info.Labels["nerdctl/name"]
		}
	}
	if len(id) > 12 {
		return id[:12]
	}
	return id
}

// pick returns the fixed address of the name, or the first free address of the range.
func pick(c ipamConfig, name string, leases map[string]lease) (string, error) {
	used := map[string]string{}
	for _, l := range leases {
		used[l.IP] = l.Name
	}
	if ip, ok := c.Addresses[name]; ok {
		if other, busy := used[ip]; busy {
			return "", fmt.Errorf("address %s of %s is used by %s", ip, name, other)
		}
		return ip, nil
	}
	reserved := map[string]bool{}
	for _, ip := range c.Addresses {
		reserved[ip] = true
	}
	start, end := toUint(net.ParseIP(c.RangeStart)), toUint(net.ParseIP(c.RangeEnd))
	if start == 0 || end < start {
		return "", errors.New("rangeStart and rangeEnd must be IPv4 addresses, start <= end")
	}
	for n := start; n <= end; n++ {
		ip := toIP(n).String()
		if _, busy := used[ip]; !busy && !reserved[ip] {
			return ip, nil
		}
	}
	return "", fmt.Errorf("no free address in %s-%s", c.RangeStart, c.RangeEnd)
}

// save writes the leases and regenerates the hosts file from them.
func save(statePath, hostsPath string, leases map[string]lease) error {
	b, _ := json.MarshalIndent(leases, "", "  ")
	if err := writeFile(statePath, b); err != nil {
		return err
	}
	lines := []string{}
	for _, l := range leases {
		lines = append(lines, fmt.Sprintf("%-15s %s", l.IP, l.Name))
	}
	sort.Strings(lines)
	hosts := "# generated by name-ipam, do not edit\r\n127.0.0.1       localhost\r\n"
	if len(lines) > 0 {
		hosts += strings.Join(lines, "\r\n") + "\r\n"
	}
	return writeFile(hostsPath, []byte(hosts))
}

// writeFile overwrites the file in place, so a bind mount of it keeps working,
// and retries while another process (an antivirus scan, a reader) holds it.
func writeFile(path string, data []byte) error {
	var err error
	for i := 0; i < 20; i++ {
		if err = os.WriteFile(path, data, 0o644); err == nil {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return err
}

func printResult(version string, c ipamConfig, ip string) error {
	_, subnet, err := net.ParseCIDR(c.Subnet)
	if err != nil {
		return fmt.Errorf("bad subnet %q: %w", c.Subnet, err)
	}
	ones, _ := subnet.Mask.Size()
	if version == "" {
		version = "0.3.0"
	}
	res := map[string]any{
		"cniVersion": version,
		"ips": []map[string]string{{
			"version": "4",
			"address": fmt.Sprintf("%s/%d", ip, ones),
			"gateway": c.Gateway,
		}},
		"routes": []map[string]string{{"dst": "0.0.0.0/0", "gw": c.Gateway}},
	}
	return json.NewEncoder(os.Stdout).Encode(res)
}

// lock creates the lock file exclusively; another plugin instance waits for it.
func lock(path string) (func(), error) {
	for i := 0; i < 100; i++ {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if err == nil {
			f.Close()
			return func() { os.Remove(path) }, nil
		}
		// A lock older than a minute is left by a crashed instance.
		if st, err := os.Stat(path); err == nil && time.Since(st.ModTime()) > time.Minute {
			os.Remove(path)
		}
		time.Sleep(100 * time.Millisecond)
	}
	return nil, fmt.Errorf("cannot take lock %s", path)
}

func toUint(ip net.IP) uint32 {
	ip = ip.To4()
	if ip == nil {
		return 0
	}
	return binary.BigEndian.Uint32(ip)
}

func toIP(n uint32) net.IP {
	ip := make(net.IP, 4)
	binary.BigEndian.PutUint32(ip, n)
	return ip
}
