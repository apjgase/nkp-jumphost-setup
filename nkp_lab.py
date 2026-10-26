#!/usr/bin/env python3
"""API helper for nkp-jumphost-setup.sh: Prism Central, Kubernetes (through kubectl), Harbor, IP math.

Python 3.9 standard library only, so it runs on a dark site jump host. The shell script keeps the
prompts and the nkp CLI calls and calls this file for everything that talks to an API.

Output: lists as one item per line (tab-separated fields), records as KEY=value lines, booleans
as the exit status. Messages go to stderr. Secrets come from the environment, never from argv:
  Prism Central  NKP_PC_ENDPOINT NKP_PC_USER NKP_PC_PASSWORD NKP_PC_TLS (insecure | trusted | CA file)
  Harbor         NKP_HARBOR_URL NKP_HARBOR_CA NKP_HARBOR_USER NKP_HARBOR_PASSWORD
  Cache          NKP_CACHE (directory for the Prism Central VM list)
"""

import argparse
import base64
import concurrent.futures
import datetime
import ipaddress
import json
import os
import random
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GIB = 1024 ** 3


class Fail(Exception):
    """A user-facing error: printed without a traceback, exit status 1 unless code is given."""

    def __init__(self, msg, code=1):
        super().__init__(msg)
        self.code = code


def say(msg):
    print(msg, file=sys.stderr)


def kv(**pairs):
    for k, v in pairs.items():
        if v is None:
            v = ""
        if not isinstance(v, str):
            v = json.dumps(v, separators=(",", ":"))
        if "\n" in v:
            raise ValueError(f"{k} contains a newline")
        print(f"{k}={v}")


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(path, 0o600)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def tls_context(mode):
    if not mode or mode == "insecure":
        return ssl._create_unverified_context()
    if mode == "trusted":
        return ssl.create_default_context()
    return ssl.create_default_context(cafile=mode)


class Http:
    def __init__(self, base, user, password, tls, timeout=30):
        self.base = base.rstrip("/")
        self.ctx = tls_context(tls)
        self.timeout = timeout
        token = base64.b64encode(f"{user}:{password}".encode()).decode() if user and password else None
        self.headers = {"Accept": "application/json"}
        if token:
            self.headers["Authorization"] = "Basic " + token

    def request(self, method, path, body=None):
        """-> (status, parsed JSON or text). Network errors raise Fail."""
        data = None
        headers = dict(self.headers)
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
                status, raw = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read()
        except (urllib.error.URLError, OSError) as e:
            raise Fail(f"Cannot reach {self.base}: {getattr(e, 'reason', e)}")
        text = raw.decode(errors="replace")
        try:
            return status, json.loads(text) if text.strip() else None
        except ValueError:
            return status, text

    def api(self, method, path, body=None):
        status, out = self.request(method, path, body)
        if not 200 <= status < 300:
            raise Fail(f"{method} {path}: HTTP {status}: {error_text(out)}", code=2)
        return out


def error_text(out):
    if isinstance(out, dict):
        msgs = [m.get("message", "") for m in out.get("message_list", []) if isinstance(m, dict)]
        if msgs:
            return "; ".join(msgs)
        for k in ("message", "errors"):
            if k in out:
                return json.dumps(out[k])[:300]
    return str(out)[:300]


# ---------------------------------------------------------------------------
# Prism Central
# ---------------------------------------------------------------------------

def pc():
    e = os.environ
    if not e.get("NKP_PC_ENDPOINT"):
        raise Fail("NKP_PC_ENDPOINT is not set")
    return Http(e["NKP_PC_ENDPOINT"], e.get("NKP_PC_USER", ""), e.get("NKP_PC_PASSWORD", ""), e.get("NKP_PC_TLS", "insecure"))


def pc_list(client, kind, length=500):
    return client.api("POST", f"/api/nutanix/v3/{kind}s/list", {"kind": kind, "length": length}).get("entities", [])


def is_pc(entity):
    return "PRISM_CENTRAL" in (entity.get("status", {}).get("resources", {}).get("config", {}).get("service_list") or [])


def subnet_cluster_ok(entity, cluster):
    name = (entity.get("status", {}).get("cluster_reference") or {}).get("name") \
        or (entity.get("spec", {}).get("cluster_reference") or {}).get("name") or ""
    return name in ("", cluster)


def pool_ranges(ip_config):
    return ",".join("-".join(p["range"].split()) for p in (ip_config or {}).get("pool_list") or [] if p.get("range"))


def ranges_to_pools(ranges):
    return [{"range": r.replace("-", " ", 1)} for r in ranges.split(",") if r.strip()]


def load_vms(client):
    """Every VM (paged), cached in NKP_CACHE for 10 minutes."""
    cache = os.environ.get("NKP_CACHE")
    path = os.path.join(cache, "pc-vms.json") if cache else None
    if path and os.path.exists(path) and time.time() - os.path.getmtime(path) < 600:
        with open(path) as f:
            return json.load(f)
    vms, offset, total = [], 0, 1
    while offset < total:
        page = client.api("POST", "/api/nutanix/v3/vms/list", {"kind": "vm", "length": 250, "offset": offset})
        total = (page.get("metadata") or {}).get("total_matches", 0)
        ents = page.get("entities") or []
        if not ents:
            break
        vms.extend(ents)
        offset += len(ents)
    if path:
        os.makedirs(cache, mode=0o700, exist_ok=True)
        write_private(path, json.dumps(vms))
    return vms


def ntp_servers(clusters, cluster):
    def ntp(entity):
        out = []
        def walk(o):
            if isinstance(o, dict):
                for k, v in o.items():
                    if k == "ntp_server_ip_list" and isinstance(v, list):
                        for x in v:
                            if isinstance(x, str):
                                out.append(x)
                            elif isinstance(x, dict):
                                val = (x.get("ipv4") or {}).get("value") or (x.get("fqdn") or {}).get("value") or x.get("value")
                                if val:
                                    out.append(val)
                    else:
                        walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        walk(entity)
        return out
    pcs = sorted({s for e in clusters if is_pc(e) for s in ntp(e)})
    pes = sorted({s for e in clusters if e.get("status", {}).get("name") == cluster for s in ntp(e)})
    return ",".join(pcs or pes)


def vm_ipv4s(vm):
    for nic in vm.get("status", {}).get("resources", {}).get("nic_list") or []:
        for ep in nic.get("ip_endpoint_list") or []:
            ip = ep.get("ip")
            if ip:
                yield ip


def lab_dns_ip(vms, name):
    name = name.lower()
    best = []
    for vm in vms:
        vm_name = (vm.get("status", {}).get("name") or vm.get("spec", {}).get("name") or "").lower()
        if name not in vm_name:
            continue
        ips = [ip for ip in vm_ipv4s(vm) if all(p.isdigit() for p in ip.split(".")) and ip.count(".") == 3]
        if ips:
            best.append((vm_name != name, ips[0]))
    return sorted(best)[0][1] if best else ""


def used_ips(subnet, clusters, vms, hosts, pc_host):
    used = set()
    for vm in vms:
        used.update(vm_ipv4s(vm))
    for e in clusters:
        for part in ("status", "spec"):
            net = (e.get(part) or {}).get("resources", {}).get("network") or {}
            for k in ("external_ip", "external_data_services_ip"):
                if isinstance(net.get(k), str):
                    used.add(net[k])
    try:
        ipaddress.ip_address(pc_host)
        used.add(pc_host)
    except ValueError:
        pass
    for h in hosts:
        res = h.get("status", {}).get("resources", {})
        for k in ("hypervisor", "controller_vm", "ipmi"):
            ip = (res.get(k) or {}).get("ip")
            if isinstance(ip, str):
                used.add(ip)
    ipc = subnet.get("spec", {}).get("resources", {}).get("ip_config") or {}
    for ip in (ipc.get("default_gateway_ip"), (ipc.get("dhcp_server_address") or {}).get("ip")):
        if isinstance(ip, str):
            used.add(ip)
    return used


def ip_select(pools_s, used, mx, mn, keep):
    """-> plan dict, or None when no run of mn free addresses exists (keeping keep for nodes)."""
    A = ipaddress.ip_address
    pools = []
    for p in pools_s.split(","):
        if p.strip():
            lo, hi = (int(A(x.strip())) for x in p.split("-", 1))
            pools.append((lo, hi))
    usedi = set()
    for u in used:
        try:
            usedi.add(int(A(u.strip())))
        except ValueError:
            pass
    runs = []
    for lo, hi in pools:
        start = None
        for ip in range(lo, hi + 1):
            if ip in usedi:
                if start is not None:
                    runs.append((start, ip - 1))
                start = None
            elif start is None:
                start = ip
        if start is not None:
            runs.append((start, hi))
    free = sum(hi - lo + 1 for lo, hi in runs)
    runs = [r for r in runs if r[1] - r[0] + 1 >= mn]
    if not runs:
        return None
    lo, hi = max(runs, key=lambda r: r[1])
    n = min(mx, hi - lo + 1, free - keep)
    if n < mn:
        return None
    b = list(range(hi - n + 1, hi + 1))
    s = lambda i: str(A(i))  # noqa: E731
    half = (n - 2) // 2
    new = []
    for plo, phi in pools:
        if plo <= b[0] and b[-1] <= phi:
            if plo < b[0]:
                new.append((plo, b[0] - 1))
            if b[-1] < phi:
                new.append((b[-1] + 1, phi))
        else:
            new.append((plo, phi))
    return {
        "IP_PLAN_COUNT": str(n),
        "IP_PLAN_BLOCK": f"{s(b[0])}-{s(b[-1])}",
        "IP_PLAN_NEW_POOLS": ",".join(f"{s(x)}-{s(y)}" for x, y in new),
        "MGMT_CONTROLPLANE_IP": s(b[0]),
        "WL_CONTROLPLANE_IP": s(b[1]),
        "MGMT_LB_RANGE": f"{s(b[2])}-{s(b[1 + half])}",
        "WL_LB_RANGE": f"{s(b[2 + half])}-{s(b[1 + 2 * half])}",
    }


def ping(ip):
    return subprocess.call(["ping", "-c1", "-W1", ip], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def range_ips(r):
    lo, hi = (int(ipaddress.ip_address(x.strip())) for x in r.split("-", 1))
    return [str(ipaddress.ip_address(i)) for i in range(lo, hi + 1)]


def responders(r):
    ips = range_ips(r)
    with concurrent.futures.ThreadPoolExecutor(32) as ex:
        return [ip for ip, up in zip(ips, ex.map(ping, ips)) if up]


def dns_answers(server, name):
    qid = random.randint(0, 65535)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
    q += struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(q, (server, 53))
        data = s.recv(4096)
    except OSError:
        return False
    finally:
        s.close()
    rid, flags, _, answers = struct.unpack(">HHHH", data[:8])
    return rid == qid and flags & 0x000F == 0 and answers > 0


def subnet_body(subnet, pools=None, dhcp="keep"):
    """PUT body: the subnet's spec with a new pool list and DHCP options (keep | unset | merge:JSON | set:JSON)."""
    spec = json.loads(json.dumps(subnet.get("spec", {})))
    ipc = spec.setdefault("resources", {}).setdefault("ip_config", {})
    if pools is not None:
        ipc["pool_list"] = pools
    if dhcp == "unset":
        ipc.pop("dhcp_options", None)
    elif dhcp.startswith("merge:"):
        ipc["dhcp_options"] = dict(ipc.get("dhcp_options") or {}, **json.loads(dhcp[6:]))
    elif dhcp.startswith("set:"):
        ipc["dhcp_options"] = json.loads(dhcp[4:])
    return {"api_version": subnet.get("api_version") or "3.1", "metadata": subnet.get("metadata"), "spec": spec}


class TaskFailed(Fail):
    pass


def wait_task(client, task, sleep=2, tries=90):
    for _ in range(tries):
        try:
            out = client.api("GET", f"/api/nutanix/v3/tasks/{task}") or {}
        except Fail:
            out = {}
        status = out.get("status")
        if status == "SUCCEEDED":
            return
        if status in ("FAILED", "ABORTED"):
            why = out.get("error_detail") or "; ".join(m.get("message", "") for m in out.get("message_list") or []
                                                       if isinstance(m, dict))
            raise TaskFailed(f"Subnet update task {task} {status}" + (f": {why}" if why else "."))
        time.sleep(sleep)
    raise Fail(f"Subnet update task {task} did not finish within {sleep * tries // 60} minutes.")


def subnet_set(client, uuid, pools, dhcp, attempts=3):
    """Prism Central can fail the task while it is still releasing the addresses of just-deleted VMs; retry then."""
    pause = float(os.environ.get("NKP_RETRY_SLEEP", "30"))
    for attempt in range(1, attempts + 1):
        subnet = client.api("GET", f"/api/nutanix/v3/subnets/{uuid}")
        status, out = client.request("PUT", f"/api/nutanix/v3/subnets/{uuid}", subnet_body(subnet, pools, dhcp))
        if not 200 <= status < 300:
            raise Fail(f"Prism Central rejected the subnet update (HTTP {status}): {error_text(out)}")
        task = ((out or {}).get("status") or {}).get("execution_context", {}).get("task_uuid") if isinstance(out, dict) else None
        try:
            if task:
                wait_task(client, task)
            break
        except TaskFailed as e:
            if attempt == attempts:
                raise
            say(f"    ! {e} Retrying in {pause:g} s ({attempt}/{attempts - 1}).")
            time.sleep(pause)
    return pool_ranges(client.api("GET", f"/api/nutanix/v3/subnets/{uuid}").get("spec", {}).get("resources", {}).get("ip_config"))


def capacity(client, pe_uuid, container):
    out = {"HOSTS": "", "CORES": "0", "HOST_MEM_GIB": "0", "VM_VCPU": "0", "VM_MEM_GIB": "0", "SC_FREE_GIB": "", "VMS_OK": "N"}
    hosts = (client.api("GET", f"/api/clustermgmt/v4.0/config/clusters/{pe_uuid}/hosts") or {}).get("data") or []
    out["HOSTS"] = str(len(hosts))
    out["CORES"] = str(sum(h.get("numberOfCpuCores") or 0 for h in hosts))
    out["HOST_MEM_GIB"] = str(sum(h.get("memorySizeBytes") or 0 for h in hosts) // GIB)
    try:
        vms = load_vms(client)
        on = [v["status"]["resources"] for v in vms
              if (v.get("status", {}).get("cluster_reference") or {}).get("uuid") == pe_uuid
              and v["status"].get("resources", {}).get("power_state") == "ON"]
        out["VM_VCPU"] = str(sum((r.get("num_sockets") or 1) * (r.get("num_vcpus_per_socket") or 1) for r in on))
        out["VM_MEM_GIB"] = str(sum(r.get("memory_size_mib") or 0 for r in on) // 1024)
        out["VMS_OK"] = "Y"
    except Fail:
        pass
    try:
        scs = (client.api("GET", "/api/clustermgmt/v4.0/config/storage-containers?$limit=100") or {}).get("data") or []
        sc = next((c for c in scs if c.get("name") == container and (c.get("clusterExtId") or pe_uuid) == pe_uuid), None)
        if sc and sc.get("maxCapacityBytes"):
            used = 0
            sid = sc.get("containerExtId") or sc.get("extId")
            if sid:
                now = datetime.datetime.utcnow().replace(microsecond=0)
                q = urllib.parse.urlencode({"$startTime": (now - datetime.timedelta(hours=1)).isoformat() + "Z",
                                            "$endTime": now.isoformat() + "Z", "$statType": "LAST", "$samplingInterval": "3600"})
                try:
                    st = client.api("GET", f"/api/clustermgmt/v4.0/stats/storage-containers/{sid}?{q}") or {}
                    vals = [x.get("value") for x in (st.get("data") or {}).get("storageUsageBytes") or [] if x.get("value") is not None]
                    used = vals[-1] if vals else 0
                except Fail:
                    pass
            out["SC_FREE_GIB"] = str((sc["maxCapacityBytes"] - used) // GIB)
    except Fail:
        pass
    return out


# ---------------------------------------------------------------------------
# TLS certificates
# ---------------------------------------------------------------------------

def is_ip(s):
    try:
        ipaddress.ip_address(s)
        return True
    except ValueError:
        return False


def fetch_cert(host, port):
    ctx = ssl._create_unverified_context()
    with socket.create_connection((host, port), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname=None if is_ip(host) else host) as s:
            return ssl.DER_cert_to_PEM_cert(s.getpeercert(True))


def tls_probe(url):
    """0 = reachable with a certificate this host trusts, 1 = reachable but untrusted, 2 = unreachable."""
    u = urllib.parse.urlsplit(url)
    host, port = u.hostname, u.port or 443
    try:
        with socket.create_connection((host, port), timeout=10) as sock:
            with ssl.create_default_context().wrap_socket(sock, server_hostname=host):
                return 0
    except ssl.SSLError:
        return 1
    except OSError:
        return 2


def cert_names(pem_file):
    return ssl._ssl._test_decode_cert(pem_file).get("subjectAltName", ())


def cert_covers(sans, host):
    host = host.lower()
    ip = ipaddress.ip_address(host) if is_ip(host) else None
    for kind, value in sans:
        value = value.strip().lower()
        if ip is not None and kind == "IP Address":
            try:
                if ipaddress.ip_address(value) == ip:
                    return True
            except ValueError:
                pass
        elif ip is None and kind == "DNS":
            if value == host or (value.startswith("*.") and host.partition(".")[2] == value[2:]):
                return True
    return False


# ---------------------------------------------------------------------------
# IP math (exit status answers)
# ---------------------------------------------------------------------------

def _rng(s):
    lo, hi = (ipaddress.ip_address(x.strip()) for x in s.split("-", 1))
    if hi < lo:
        raise ValueError
    return lo, hi


def _rngs(s):
    return [_rng(x) for x in s.split(",") if x.strip()]


def ip_op(op, a):
    try:
        if op == "ip":
            ipaddress.ip_address(a[0])
            return True
        if op == "cidr":
            ipaddress.ip_network(a[0], strict=False)
            return "/" in a[0]
        if op == "range":
            _rng(a[0])
            return True
        if op == "ip_in_cidr":
            return ipaddress.ip_address(a[0]) in ipaddress.ip_network(a[1], strict=False)
        if op == "range_in_cidr":
            n = ipaddress.ip_network(a[1], strict=False)
            lo, hi = _rng(a[0])
            return lo in n and hi in n
        if op == "ip_in_ranges":
            ip = ipaddress.ip_address(a[0])
            return any(lo <= ip <= hi for lo, hi in _rngs(a[1]))
        if op == "range_in_ranges":
            lo, hi = _rng(a[0])
            return any(l <= lo and hi <= h for l, h in _rngs(a[1]))  # noqa: E741
        if op == "range_overlaps":
            lo, hi = _rng(a[0])
            return any(lo <= h and l <= hi for l, h in _rngs(a[1]))  # noqa: E741
        if op == "cidr_overlap":
            return ipaddress.ip_network(a[0], strict=False).overlaps(ipaddress.ip_network(a[1], strict=False))
        if op == "range_first":
            print(_rng(a[0])[0])
            return True
    except (ValueError, IndexError, TypeError):
        return False
    return False


# ---------------------------------------------------------------------------
# Kubernetes through kubectl (it handles every kubeconfig auth method)
# ---------------------------------------------------------------------------

class Kube:
    def __init__(self, kubeconfig):
        self.base = ["kubectl", "--kubeconfig", kubeconfig]

    def run(self, *args, stdin=None, check=True):
        p = subprocess.run(self.base + list(args), input=stdin, capture_output=True, text=True)
        if check and p.returncode != 0:
            raise Fail(f"kubectl {' '.join(args)}: {p.stderr.strip()[:300]}", code=2)
        return p

    def json(self, *args, check=True):
        p = self.run(*args, "-o", "json", check=check)
        if p.returncode != 0:
            return None
        return json.loads(p.stdout or "null")

    def items(self, *args):
        out = self.json("get", *args, check=False)
        return (out or {}).get("items", [])

    def apply(self, obj):
        self.run("apply", "-f", "-", stdin=json.dumps(obj))


def hr_not_ready(k, ns):
    """-> list of (name, message) not Ready; None when the namespace has no HelmRelease yet."""
    items = k.items("-n", ns, "helmreleases.helm.toolkit.fluxcd.io")
    if not items:
        return None
    bad = []
    for hr in items:
        ready = next((c for c in hr.get("status", {}).get("conditions") or [] if c.get("type") == "Ready"), {})
        if ready.get("status") != "True":
            bad.append((hr["metadata"]["name"], (ready.get("message") or ready.get("reason") or "not ready").replace("\n", " ")[:160]))
    return bad


def starved_pods(k):
    out = []
    for p in k.items("pods", "-A", "--field-selector=status.phase=Pending"):
        for c in p.get("status", {}).get("conditions") or []:
            if c.get("type") == "PodScheduled" and c.get("status") == "False" and \
                    any(s in (c.get("message") or "") for s in ("Insufficient cpu", "Insufficient memory")):
                out.append(f"{p['metadata']['namespace']}/{p['metadata']['name']}")
                break
    return out


def md0(k, cluster):
    for md in k.items("machinedeployments.cluster.x-k8s.io", "-A", "-l", f"cluster.x-k8s.io/cluster-name={cluster}"):
        name = (md["metadata"].get("labels") or {}).get("topology.cluster.x-k8s.io/deployment-name") or md["metadata"]["name"]
        if "md-0" in name:
            return md["metadata"]["namespace"], md["metadata"]["name"], md.get("spec", {}).get("replicas")
    return None


def reserved_ranges(clusters):
    out = []
    def walk(o):
        if isinstance(o, dict):
            if isinstance(o.get("addressRanges"), list):
                for r in o["addressRanges"]:
                    if isinstance(r, dict) and r.get("start") and r.get("end"):
                        out.append(f"{r['start']}-{r['end']}")
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    for c in clusters:
        host = (c.get("spec", {}).get("controlPlaneEndpoint") or {}).get("host") or ""
        if is_ip(host):
            out.append(f"{host}-{host}")
        walk(c)
    seen = []
    for r in out:
        if r not in seen:
            seen.append(r)
    return ",".join(seen)


HOST_SEL = ["-l", "kommander.d2iq.io/host=true"]


def ncr_info(k):
    """-> (host, base64 CA) of the management cluster's ingress, where Harbor listens on :5000."""
    kc = (k.items("-n", "kommander", "kommanderclusters", *HOST_SEL) or [{}])[0]
    ing = kc.get("status", {}).get("ingress") or {}
    host, ca = ing.get("address") or "", ing.get("caBundle") or ""
    if not ca:
        nc = (k.items("-n", "kommander", "nkpclusters", *HOST_SEL) or [{}])[0]
        ca = ((nc.get("kommanderCluster") or {}).get("status", {}).get("ingress") or {}).get("caBundle") or ""
    return host, ca


def harbor_admin_password(k):
    s = k.json("-n", "ncr-system", "get", "secret", "harbor-admin-password", check=False)
    v = ((s or {}).get("data") or {}).get("HARBOR_ADMIN_PASSWORD")
    return base64.b64decode(v).decode() if v else ""


def cluster_app(k, prefix):
    """Newest ClusterApp named <prefix>-<version>."""
    names = [a["metadata"]["name"] for a in k.items("clusterapps.apps.kommander.d2iq.io")
             if a["metadata"]["name"].startswith(prefix + "-") and a["metadata"]["name"][len(prefix) + 1:][:1].isdigit()]
    def ver(n):
        return [int(x) if x.isdigit() else 0 for x in n[len(prefix) + 1:].replace("-", ".").split(".")]
    return sorted(names, key=ver)[-1] if names else ""


def appdeployment(name, ns, app, overrides=None):
    spec = {"appRef": {"name": app, "kind": "ClusterApp"}}
    if overrides:
        spec["configOverrides"] = {"name": overrides}
    return {"apiVersion": "apps.kommander.d2iq.io/v1alpha3", "kind": "AppDeployment",
            "metadata": {"name": name, "namespace": ns}, "spec": spec}


def configmap(name, ns, values):
    return {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": ns},
            "data": {"values.yaml": values if isinstance(values, str) else json.dumps(values, indent=2)}}


def ceph_override(count):
    """The storageClassDeviceSets entry from the guide's 'Increasing Rook Ceph Storage Capacity' (40 GiB PVs)."""
    spread = lambda key: {"maxSkew": 1, "topologyKey": key, "whenUnsatisfiable": "ScheduleAnyway",  # noqa: E731
                          "labelSelector": {"matchExpressions": [{"key": "app", "operator": "In",
                                                                  "values": ["rook-ceph-osd", "rook-ceph-osd-prepare"]}]}}
    return {"cephClusterSpec": {
        "labels": {"monitoring": {"prometheus.kommander.d2iq.io/select": "true"}},
        "storage": {"storageClassDeviceSets": [{
            "name": "rook-ceph-osd-set1", "count": count, "portable": True, "encrypted": False,
            "placement": {"topologySpreadConstraints": [spread("topology.kubernetes.io/zone"), spread("kubernetes.io/hostname")]},
            "volumeClaimTemplates": [{"metadata": {"name": "data"}, "spec": {
                "resources": {"requests": {"storage": "40Gi"}}, "volumeMode": "Block", "accessModes": ["ReadWriteOnce"]}}]}]}}}


HARBOR_BUCKET = "harbor-registry"


def harbor_s3_values(bucket, endpoint):
    """Best guess of the Rook Ceph S3 settings the NKP UI writes for Harbor; replace with HARBOR_OVERRIDES_FILE if they differ."""
    return {
        "harborCopySecret": {"enabled": True},
        "persistence": {"imageChartStorage": {"type": "s3", "s3": {
            "existingSecret": "harbor-s3-credentials", "bucket": bucket, "region": "us-east-1",
            "regionendpoint": endpoint, "secure": False, "v4auth": True}}},
    }


def harbor_deploy(k, ns, overrides_file, ceph_count, wait_min):
    """CloudNativePG, more Rook Ceph capacity, an object bucket and Harbor, as in 'Deploying Harbor on a Management Cluster'."""
    apps = {n: cluster_app(k, n) for n in ("cloudnative-pg", "rook-ceph-cluster", "harbor")}
    for n in ("cloudnative-pg", "harbor"):
        if not apps[n]:
            raise Fail(f"No ClusterApp {n}-<version> on this cluster.")
    k.apply(appdeployment("cloudnative-pg", ns, apps["cloudnative-pg"]))
    say(f"    Enabled {apps['cloudnative-pg']}")

    rook = k.json("-n", ns, "get", "appdeployments.apps.kommander.d2iq.io", "rook-ceph-cluster", check=False)
    if not rook:
        say("    ! rook-ceph-cluster is not enabled on this cluster; Harbor needs it for its S3 storage.")
    elif (rook.get("spec") or {}).get("configOverrides"):
        say(f"    ! rook-ceph-cluster already has overrides ({rook['spec']['configOverrides'].get('name')}); not changing its capacity.")
    elif ceph_count:
        k.apply(configmap("rook-ceph-cluster-overrides", ns, ceph_override(ceph_count)))
        k.apply(appdeployment("rook-ceph-cluster", ns, rook["spec"]["appRef"]["name"], "rook-ceph-cluster-overrides"))
        say(f"    Rook Ceph: {ceph_count} x 40 GiB volumes")

    if overrides_file:
        with open(overrides_file) as f:
            values = f.read()
    else:
        k.apply({"apiVersion": "objectbucket.io/v1alpha1", "kind": "ObjectBucketClaim",
                 "metadata": {"name": HARBOR_BUCKET, "namespace": ns},
                 "spec": {"bucketName": HARBOR_BUCKET, "storageClassName": "dkp-object-store"}})
        secret = None
        for _ in range(60):
            secret = k.json("-n", ns, "get", "secret", HARBOR_BUCKET, check=False)
            if secret and (secret.get("data") or {}).get("AWS_ACCESS_KEY_ID"):
                break
            time.sleep(10)
        else:
            raise Fail(f"The object bucket {HARBOR_BUCKET} was not provisioned within 10 minutes (Rook Ceph object store dkp-object-store).")
        d = secret["data"]
        k.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "harbor-s3-credentials", "namespace": ns},
                 "type": "Opaque", "data": {"REGISTRY_STORAGE_S3_ACCESSKEY": d["AWS_ACCESS_KEY_ID"],
                                            "REGISTRY_STORAGE_S3_SECRETKEY": d["AWS_SECRET_ACCESS_KEY"]}})
        values = json.dumps(harbor_s3_values(HARBOR_BUCKET, f"http://rook-ceph-rgw-dkp-object-store.{ns}.svc:80"), indent=2)
    k.apply(configmap("harbor-overrides", ns, values))
    k.apply(appdeployment("harbor", ns, apps["harbor"], "harbor-overrides"))
    say(f"    Enabled {apps['harbor']}; waiting for it (up to {wait_min} minutes)...")
    deadline = time.time() + wait_min * 60
    while time.time() < deadline:
        bad = hr_not_ready(k, "ncr-system")
        if bad == [] and harbor_admin_password(k):
            return apps["harbor"]
        time.sleep(15)
    bad = hr_not_ready(k, "ncr-system") or []
    raise Fail("Harbor is not ready: " + ("; ".join(f"{n}: {m}" for n, m in bad) or "no HelmRelease in ncr-system yet"))


# ---------------------------------------------------------------------------
# Harbor API
# ---------------------------------------------------------------------------

def harbor():
    e = os.environ
    if not e.get("NKP_HARBOR_URL"):
        raise Fail("NKP_HARBOR_URL is not set")
    u = urllib.parse.urlsplit(e["NKP_HARBOR_URL"])
    return Http(f"{u.scheme}://{u.netloc}", e.get("NKP_HARBOR_USER", "admin"), e.get("NKP_HARBOR_PASSWORD", ""),
                e.get("NKP_HARBOR_CA") or "trusted")


def harbor_project_of(url):
    path = urllib.parse.urlsplit(url).path.strip("/")
    return path.split("/")[0] if path else ""


def harbor_robot(h, name, project, description):
    """Pull-only robot account on one project (or every project when project is empty); replaces one with the same name."""
    robots = h.api("GET", "/api/v2.0/robots?page_size=100") or []
    for r in robots:
        if r.get("name") == name or str(r.get("name", "")).endswith("$" + name):
            h.api("DELETE", f"/api/v2.0/robots/{r['id']}")
    body = {"name": name, "description": description, "level": "system", "duration": -1, "disable": False,
            "permissions": [{"kind": "project", "namespace": project or "*",
                             "access": [{"resource": "repository", "action": "pull"}]}]}
    out = h.api("POST", "/api/v2.0/robots", body)
    if not out or not out.get("name") or not out.get("secret"):
        raise Fail("Harbor did not return the robot account's name and secret.")
    return out["name"], out["secret"]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(prog="nkp_lab.py")
    sub = ap.add_subparsers(dest="group", required=True)

    g = sub.add_parser("ip").add_subparsers(dest="cmd", required=True)
    for op in ("ip", "cidr", "range", "ip_in_cidr", "range_in_cidr", "ip_in_ranges", "range_in_ranges",
               "range_overlaps", "cidr_overlap", "range_first"):
        g.add_parser(op).add_argument("args", nargs="*")

    g = sub.add_parser("tls").add_subparsers(dest="cmd", required=True)
    p = g.add_parser("fetch"); p.add_argument("hostport"); p.add_argument("out")
    g.add_parser("probe").add_argument("url")
    p = g.add_parser("covers"); p.add_argument("pem"); p.add_argument("host")

    g = sub.add_parser("dns").add_subparsers(dest="cmd", required=True)
    p = g.add_parser("answers"); p.add_argument("server"); p.add_argument("name")

    g = sub.add_parser("pc").add_subparsers(dest="cmd", required=True)
    p = g.add_parser("status"); p.add_argument("path")
    g.add_parser("clusters")
    p = g.add_parser("subnets"); p.add_argument("cluster")
    g.add_parser("images")
    p = g.add_parser("containers"); p.add_argument("cluster")
    p = g.add_parser("ntp"); p.add_argument("cluster")
    p = g.add_parser("ip-plan"); p.add_argument("subnet_uuid"); p.add_argument("--pc-host", default="")
    p.add_argument("--max", type=int, default=30); p.add_argument("--min", type=int, default=12)
    p.add_argument("--reserve", type=int, default=20); p.add_argument("--dns-vm", default="autoad")
    p.add_argument("--domain", default="ntnxlab.local"); p.add_argument("--no-ping", action="store_true")
    p = g.add_parser("subnet-pools"); p.add_argument("subnet_uuid")
    p = g.add_parser("subnet-set"); p.add_argument("subnet_uuid")
    p.add_argument("--pools", help="a-b,c-d"); p.add_argument("--pools-json")
    p.add_argument("--dhcp", default="keep", help="keep | unset | merge:JSON | set:JSON")
    p = g.add_parser("capacity"); p.add_argument("pe_uuid"); p.add_argument("container")

    g = sub.add_parser("k8s").add_subparsers(dest="cmd", required=True)
    def kp(name):
        q = g.add_parser(name)
        q.add_argument("--kubeconfig", required=True)
        return q
    kp("clusters"); kp("reserved-ranges"); kp("kubelet-version"); kp("workspaces")
    kp("workspace-create").add_argument("name")
    kp("hr-not-ready").add_argument("namespace")
    kp("starved-pods")
    kp("md0").add_argument("cluster")
    p = kp("hr-reconcile"); p.add_argument("namespace"); p.add_argument("names", nargs="+")
    p = kp("ncr"); p.add_argument("--ca-out")
    kp("harbor-password"); kp("uid"); kp("harbor-prereqs")
    p = kp("harbor-deploy"); p.add_argument("--namespace", default="kommander"); p.add_argument("--overrides-file")
    p.add_argument("--ceph-count", type=int, default=8); p.add_argument("--wait", type=int, default=30)

    g = sub.add_parser("harbor").add_subparsers(dest="cmd", required=True)
    g.add_parser("ping")
    g.add_parser("whoami")
    p = g.add_parser("ensure-project"); p.add_argument("name")
    p = g.add_parser("public"); p.add_argument("name")
    p = g.add_parser("repos"); p.add_argument("name")
    p = g.add_parser("robot"); p.add_argument("name"); p.add_argument("--project", default=""); p.add_argument("--description", default="")

    a = ap.parse_args(argv)
    try:
        return run(a)
    except Fail as e:
        say(f"ERROR: {e}")
        return e.code


def run(a):  # noqa: C901 - one dispatch table
    if a.group == "ip":
        return 0 if ip_op(a.cmd, a.args) else 1
    if a.group == "dns":
        return 0 if dns_answers(a.server, a.name) else 1
    if a.group == "tls":
        if a.cmd == "fetch":
            host, _, port = a.hostport.rpartition(":")
            try:
                write_private(a.out, fetch_cert(host, int(port)))
            except OSError as e:
                raise Fail(f"Cannot fetch the certificate from {a.hostport}: {e}")
            return 0
        if a.cmd == "probe":
            return tls_probe(a.url)
        try:
            sans = cert_names(a.pem)
        except Exception:  # noqa: BLE001 - unreadable certificate
            return 2
        print(", ".join(f"{k}:{v}" for k, v in sans))
        return 0 if cert_covers(sans, a.host) else 1

    if a.group == "pc":
        c = pc()
        if a.cmd == "status":
            try:
                print(c.request("GET", a.path)[0])
            except Fail:
                print("000")
            return 0
        if a.cmd == "clusters":
            for e in pc_list(c, "cluster"):
                if not is_pc(e):
                    print(f"{e['status']['name']}\t{e['metadata']['uuid']}")
            return 0
        if a.cmd == "subnets":
            for e in pc_list(c, "subnet"):
                if not subnet_cluster_ok(e, a.cluster):
                    continue
                st = e.get("status", {})
                ipc = st.get("resources", {}).get("ip_config") or {}
                cidr = f"{ipc['subnet_ip']}/{ipc['prefix_length']}" if ipc.get("subnet_ip") else ""
                pools = pool_ranges(ipc)
                label = f"{st['name']}  ({st.get('resources', {}).get('subnet_type', '?')}" + (f", {cidr}" if cidr else "") \
                    + (f", pool {pools}" if pools else ", no IPAM pool") + ")"
                print("\t".join([st["name"], e["metadata"]["uuid"], label, cidr, pools]))
            return 0
        if a.cmd == "images":
            for n in sorted({e["status"]["name"] for e in pc_list(c, "image")}):
                print(n)
            return 0
        if a.cmd == "containers":
            data = (c.api("GET", "/api/clustermgmt/v4.0/config/storage-containers?$limit=100") or {}).get("data") or []
            names = {d["name"] for d in data if (d.get("clusterName") or a.cluster) == a.cluster
                     and d.get("name") not in ("NutanixManagementShare", "SelfServiceContainer")}
            for n in sorted(names):
                print(n)
            return 0
        if a.cmd == "ntp":
            print(ntp_servers(pc_list(c, "cluster"), a.cluster))
            return 0
        if a.cmd == "subnet-pools":
            print(pool_ranges(c.api("GET", f"/api/nutanix/v3/subnets/{a.subnet_uuid}").get("spec", {}).get("resources", {}).get("ip_config")))
            return 0
        if a.cmd == "subnet-set":
            pools = json.loads(a.pools_json) if a.pools_json else (ranges_to_pools(a.pools) if a.pools is not None else None)
            print(subnet_set(c, a.subnet_uuid, pools, a.dhcp))
            return 0
        if a.cmd == "capacity":
            kv(**capacity(c, a.pe_uuid, a.container))
            return 0
        if a.cmd == "ip-plan":
            return cmd_ip_plan(c, a)

    if a.group == "k8s":
        k = Kube(a.kubeconfig)
        if a.cmd == "clusters":
            for c in (k.json("get", "clusters.cluster.x-k8s.io", "-A") or {}).get("items", []):
                print(f"{c['metadata']['namespace']}\t{c['metadata']['name']}")
            return 0
        if a.cmd == "reserved-ranges":
            out = k.json("get", "clusters.cluster.x-k8s.io", "-A", check=False)
            if out is None:
                raise Fail("Cannot list Cluster API clusters.", code=2)
            print(reserved_ranges(out.get("items", [])))
            return 0
        if a.cmd == "kubelet-version":
            nodes = k.items("nodes")
            print(nodes[0]["status"]["nodeInfo"]["kubeletVersion"] if nodes else "")
            return 0
        if a.cmd == "workspaces":
            for w in k.items("workspaces.workspaces.kommander.mesosphere.io"):
                ns = (w.get("spec") or {}).get("namespaceName") or ((w.get("status") or {}).get("namespaceRef") or {}).get("name") or ""
                if ns:
                    print(f"{w['metadata']['name']}\t{ns}")
            return 0
        if a.cmd == "workspace-create":
            k.apply({"apiVersion": "workspaces.kommander.mesosphere.io/v1alpha1", "kind": "Workspace",
                     "metadata": {"name": a.name, "annotations": {"kommander.mesosphere.io/display-name": a.name}},
                     "spec": {"namespaceName": a.name}})
            for _ in range(30):
                if k.run("get", "namespace", a.name, check=False).returncode == 0:
                    return 0
                time.sleep(2)
            raise Fail(f"Namespace {a.name} did not appear.")
        if a.cmd == "hr-not-ready":
            bad = hr_not_ready(k, a.namespace)
            if bad is None:
                return 1
            for n, m in bad:
                print(f"{n}\t{m}")
            return 0
        if a.cmd == "starved-pods":
            print("\n".join(starved_pods(k)))
            return 0
        if a.cmd == "md0":
            r = md0(k, a.cluster)
            if not r:
                return 1
            print(" ".join(str(x) for x in r))
            return 0
        if a.cmd == "hr-reconcile":
            ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
            for n in a.names:
                k.run("-n", a.namespace, "annotate", "--overwrite", f"helmreleases.helm.toolkit.fluxcd.io/{n}",
                      f"reconcile.fluxcd.io/requestedAt={ts}", f"reconcile.fluxcd.io/resetAt={ts}",
                      f"reconcile.fluxcd.io/forceAt={ts}", check=False)
            return 0
        if a.cmd == "ncr":
            host, ca = ncr_info(k)
            present = bool(k.json("-n", "ncr-system", "get", "secret", "harbor-admin-password", check=False))
            if a.ca_out and ca:
                pem = base64.b64decode(ca).decode()
                if "BEGIN CERTIFICATE" not in pem:
                    raise Fail("The ingress CA is not a PEM certificate.")
                write_private(a.ca_out, pem)
            kv(NCR_HOST=host, NCR_PRESENT="Y" if present else "N", NCR_CA_FOUND="Y" if ca else "N")
            return 0
        if a.cmd == "harbor-password":
            pw = harbor_admin_password(k)
            if not pw:
                return 1
            print(pw)
            return 0
        if a.cmd == "uid":
            ns = k.json("get", "namespace", "kube-system")
            print(ns["metadata"]["uid"])
            return 0
        if a.cmd == "harbor-prereqs":
            rook = k.json("-n", "kommander", "get", "appdeployments.apps.kommander.d2iq.io", "rook-ceph-cluster", check=False) or {}
            sc = k.json("get", "storageclass", "dkp-object-store", check=False)
            present = bool(k.json("-n", "ncr-system", "get", "secret", "harbor-admin-password", check=False))
            kv(CNPG_APP=cluster_app(k, "cloudnative-pg"), HARBOR_APP=cluster_app(k, "harbor"),
               ROOK_ENABLED="Y" if rook else "N",
               ROOK_OVERRIDES=((rook.get("spec") or {}).get("configOverrides") or {}).get("name", ""),
               OBJECT_STORE="Y" if sc else "N", NCR_HOST=ncr_info(k)[0], NCR_PRESENT="Y" if present else "N")
            return 0
        if a.cmd == "harbor-deploy":
            print(harbor_deploy(k, a.namespace, a.overrides_file, a.ceph_count, a.wait))
            return 0

    if a.group == "harbor":
        h = harbor()
        if a.cmd == "ping":
            status, _ = h.request("GET", "/api/v2.0/ping")
            return 0 if status == 200 else 1
        if a.cmd == "whoami":
            print((h.api("GET", "/api/v2.0/users/current") or {}).get("username", ""))
            return 0
        if a.cmd == "ensure-project":
            status, _ = h.request("HEAD", f"/api/v2.0/projects?project_name={urllib.parse.quote(a.name)}")
            if status == 200:
                return 0
            h.api("POST", "/api/v2.0/projects", {"project_name": a.name, "metadata": {"public": "false"}})
            say(f"    Created Harbor project {a.name}")
            return 0
        if a.cmd == "public":
            p = h.api("GET", f"/api/v2.0/projects/{urllib.parse.quote(a.name)}")
            return 0 if (p.get("metadata") or {}).get("public") == "true" else 1
        if a.cmd == "repos":
            p = h.api("GET", f"/api/v2.0/projects/{urllib.parse.quote(a.name)}")
            print(p.get("repo_count", 0))
            return 0
        if a.cmd == "robot":
            name, secret = harbor_robot(h, a.name, a.project, a.description)
            print(f"{name}\t{secret}")
            return 0
    raise Fail(f"unknown command {a.group} {a.cmd}")


def cmd_ip_plan(c, a):
    """KEY=value plan; exit 3 = no IPAM pool, 4 = no free block, 5 = only blocks with addresses answering ping."""
    subnet = c.api("GET", f"/api/nutanix/v3/subnets/{a.subnet_uuid}")
    ipc = subnet.get("spec", {}).get("resources", {}).get("ip_config") or {}
    pools = pool_ranges(ipc)
    if not pools:
        return 3
    clusters = pc_list(c, "cluster")
    try:
        vms = load_vms(c)
    except Fail:
        say("    ! Could not list the VMs; only ping will detect used addresses.")
        vms = []
    try:
        hosts = pc_list(c, "host")
    except Fail:
        hosts = []
    used = used_ips(subnet, clusters, vms, hosts, a.pc_host)
    plan = None
    for attempt in range(1, 6):
        plan = ip_select(pools, used, a.max, a.min, a.reserve)
        if plan is None:
            return 4
        up = [] if a.no_ping else responders(plan["IP_PLAN_BLOCK"])
        if not up:
            break
        say(f"    ! Attempt {attempt}: addresses answering ping in the candidate block: {' '.join(up)}")
        used.update(up)
    else:
        return 5
    dns_ip = lab_dns_ip(vms, a.dns_vm)
    dns_ok = bool(dns_ip) and dns_answers(dns_ip, a.domain)
    kv(**plan, POOLS=pools, IP_PLAN_ORIGINAL_POOLS=ipc.get("pool_list") or [],
       IP_PLAN_ORIGINAL_DHCP=json.dumps(ipc.get("dhcp_options"), separators=(",", ":")),
       DNS_VM_IP=dns_ip, DNS_OK="Y" if dns_ok else "N")
    return 0


if __name__ == "__main__":
    sys.exit(main())
