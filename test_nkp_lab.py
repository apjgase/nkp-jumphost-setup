#!/usr/bin/env python3
"""Tests for nkp_lab.py against a fake Prism Central and Harbor (python3 -m unittest test_nkp_lab)."""

import base64
import contextlib
import io
import json
import os
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import nkp_lab

AUTH = "Basic " + base64.b64encode(b"admin:secret").decode()

SUBNET = {
    "api_version": "3.1",
    "metadata": {"uuid": "sub-1", "kind": "subnet", "spec_version": 3},
    "status": {"name": "primary", "cluster_reference": {"name": "PE1"},
               "resources": {"subnet_type": "VLAN", "ip_config": {
                   "subnet_ip": "10.0.0.0", "prefix_length": 24,
                   "pool_list": [{"range": "10.0.0.100 10.0.0.200"}]}}},
    "spec": {"name": "primary", "resources": {"subnet_type": "VLAN", "ip_config": {
        "subnet_ip": "10.0.0.0", "prefix_length": 24, "default_gateway_ip": "10.0.0.1",
        "pool_list": [{"range": "10.0.0.100 10.0.0.200"}],
        "dhcp_options": {"domain_name_server_list": ["8.8.8.8"]}}}},
}


def vm(name, ip, cluster="pe-1", on=True, vcpu=2, mem=4096):
    return {"status": {"name": name, "cluster_reference": {"uuid": cluster},
                       "resources": {"power_state": "ON" if on else "OFF", "num_sockets": vcpu,
                                     "num_vcpus_per_socket": 1, "memory_size_mib": mem,
                                     "nic_list": [{"ip_endpoint_list": [{"ip": ip}]}]}}}


class Fake:
    def __init__(self):
        self.subnet = json.loads(json.dumps(SUBNET))
        self.puts = []
        self.vms = [vm("autoad", "10.0.0.5"), vm("app", "10.0.0.200"), vm("db", "10.0.0.199", on=False)]
        self.projects = {"nkp": {"name": "nkp", "repo_count": 3, "metadata": {"public": "false"}}}
        self.robots = [{"id": 7, "name": "robot$nkp-wl1"}]
        self.deleted = []
        self.created_robot = None
        self.fail_tasks = 0


class Handler(BaseHTTPRequestHandler):
    fake = None

    def log_message(self, *a):
        pass

    def send(self, code, body=None):
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(raw)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"null")

    def route(self):
        f = self.fake
        if self.path == "/api/v2.0/ping":
            return self.send(200, "Pong")
        if self.headers.get("Authorization") != AUTH:
            return self.send(401, {"message": "unauthorized"})
        u = urllib.parse.urlsplit(self.path)
        p, q = u.path, urllib.parse.parse_qs(u.query)
        m = self.command
        if p == "/api/nutanix/v3/users/me":
            return self.send(200, {})
        if p == "/api/nutanix/v3/clusters/list":
            return self.send(200, {"entities": [
                {"metadata": {"uuid": "pe-1"}, "status": {"name": "PE1", "resources": {
                    "config": {"service_list": ["AOS"]}, "network": {"external_ip": "10.0.0.10",
                                                                     "ntp_server_ip_list": ["1.pool.ntp.org"]}}}},
                {"metadata": {"uuid": "pc-1"}, "status": {"name": "PC", "resources": {
                    "config": {"service_list": ["PRISM_CENTRAL"]},
                    "network": {"ntp_server_ip_list": [{"fqdn": {"value": "ntp.lab"}}]}}}}]})
        if p == "/api/nutanix/v3/subnets/list":
            other = {"metadata": {"uuid": "sub-2"}, "status": {"name": "elsewhere", "cluster_reference": {"name": "PE2"},
                                                             "resources": {"subnet_type": "VLAN"}}}
            return self.send(200, {"entities": [f.subnet, other]})
        if p == "/api/nutanix/v3/subnets/sub-1":
            if m == "PUT":
                b = self.body()
                f.puts.append(b)
                f.subnet["spec"] = b["spec"]
                f.subnet["status"]["resources"]["ip_config"]["pool_list"] = b["spec"]["resources"]["ip_config"].get("pool_list", [])
                return self.send(202, {"status": {"execution_context": {"task_uuid": "t1"}}})
            return self.send(200, f.subnet)
        if p == "/api/nutanix/v3/tasks/t1":
            if f.fail_tasks:
                f.fail_tasks -= 1
                return self.send(200, {"status": "FAILED", "error_detail": "IP 10.0.0.170 is in use"})
            return self.send(200, {"status": "SUCCEEDED"})
        if p == "/api/nutanix/v3/vms/list":
            b = self.body()
            page = f.vms[b["offset"]:b["offset"] + 2]
            return self.send(200, {"metadata": {"total_matches": len(f.vms)}, "entities": page})
        if p == "/api/nutanix/v3/hosts/list":
            return self.send(200, {"entities": [{"status": {"resources": {
                "hypervisor": {"ip": "10.0.0.11"}, "controller_vm": {"ip": "10.0.0.12"}}}}]})
        if p == "/api/nutanix/v3/images/list":
            return self.send(200, {"entities": [{"status": {"name": "nkp-rocky-9.6-release-1.36.2"}},
                                                {"status": {"name": "ubuntu"}}]})
        if p == "/api/clustermgmt/v4.0/config/storage-containers":
            return self.send(200, {"data": [
                {"name": "default", "clusterName": "PE1", "clusterExtId": "pe-1", "extId": "sc-1",
                 "maxCapacityBytes": 1000 * nkp_lab.GIB},
                {"name": "NutanixManagementShare", "clusterName": "PE1"},
                {"name": "other", "clusterName": "PE2"}]})
        if p == "/api/clustermgmt/v4.0/config/clusters/pe-1/hosts":
            return self.send(200, {"data": [{"numberOfCpuCores": 32, "memorySizeBytes": 512 * nkp_lab.GIB}] * 3})
        if p == "/api/clustermgmt/v4.0/stats/storage-containers/sc-1":
            return self.send(200, {"data": {"storageUsageBytes": [{"value": 100 * nkp_lab.GIB}, {"value": 400 * nkp_lab.GIB}]}})
        if p == "/api/v2.0/users/current":
            return self.send(200, {"username": "admin"})
        if p == "/api/v2.0/projects" and m == "HEAD":
            return self.send(200 if q["project_name"][0] in f.projects else 404)
        if p == "/api/v2.0/projects" and m == "POST":
            b = self.body()
            f.projects[b["project_name"]] = {"name": b["project_name"], "repo_count": 0, "metadata": b["metadata"]}
            return self.send(201)
        if p.startswith("/api/v2.0/projects/"):
            name = urllib.parse.unquote(p.rsplit("/", 1)[1])
            return self.send(200, f.projects[name]) if name in f.projects else self.send(404, {"errors": []})
        if p == "/api/v2.0/robots" and m == "GET":
            return self.send(200, f.robots)
        if p.startswith("/api/v2.0/robots/") and m == "DELETE":
            f.deleted.append(int(p.rsplit("/", 1)[1]))
            return self.send(200)
        if p == "/api/v2.0/robots" and m == "POST":
            f.created_robot = self.body()
            return self.send(201, {"name": "robot$" + f.created_robot["name"], "secret": "s3cr3t"})
        return self.send(404, {"message": f"no route {m} {p}"})

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = route


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = nkp_lab.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


def kv(text):
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


class ServerTest(unittest.TestCase):
    def setUp(self):
        Handler.fake = self.fake = Fake()
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_port}"
        self.cache = tempfile.mkdtemp()
        self.env = {"NKP_PC_ENDPOINT": self.url, "NKP_PC_USER": "admin", "NKP_PC_PASSWORD": "secret",
                    "NKP_PC_TLS": "insecure", "NKP_CACHE": self.cache,
                    "NKP_HARBOR_URL": self.url + "/nkp", "NKP_HARBOR_USER": "admin", "NKP_HARBOR_PASSWORD": "secret"}
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


class PrismCentral(ServerTest):
    def test_status(self):
        self.assertEqual(run("pc", "status", "/api/nutanix/v3/users/me")[1].strip(), "200")
        os.environ["NKP_PC_PASSWORD"] = "wrong"
        self.assertEqual(run("pc", "status", "/api/nutanix/v3/users/me")[1].strip(), "401")
        os.environ["NKP_PC_ENDPOINT"] = "http://127.0.0.1:1"
        self.assertEqual(run("pc", "status", "/")[1].strip(), "000")

    def test_inventory(self):
        self.assertEqual(run("pc", "clusters")[1], "PE1\tpe-1\n")
        rows = [r.split("\t") for r in run("pc", "subnets", "PE1")[1].splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:2], ["primary", "sub-1"])
        self.assertEqual(rows[0][2], "primary  (VLAN, 10.0.0.0/24, pool 10.0.0.100-10.0.0.200)")
        self.assertEqual(rows[0][3:], ["10.0.0.0/24", "10.0.0.100-10.0.0.200"])
        self.assertEqual(run("pc", "images")[1].split(), ["nkp-rocky-9.6-release-1.36.2", "ubuntu"])
        self.assertEqual(run("pc", "containers", "PE1")[1], "default\n")
        self.assertEqual(run("pc", "ntp", "PE1")[1].strip(), "ntp.lab")

    def test_ip_plan(self):
        rc, out, _ = run("pc", "ip-plan", "sub-1", "--pc-host", "10.0.0.20", "--no-ping")
        self.assertEqual(rc, 0)
        plan = kv(out)
        # 10.0.0.200 is a VM NIC and 10.0.0.199 (powered off) still holds its address: the block ends at .198
        self.assertEqual(plan["IP_PLAN_BLOCK"], "10.0.0.169-10.0.0.198")
        self.assertEqual(plan["IP_PLAN_NEW_POOLS"], "10.0.0.100-10.0.0.168,10.0.0.199-10.0.0.200")
        self.assertEqual(plan["MGMT_CONTROLPLANE_IP"], "10.0.0.169")
        self.assertEqual(plan["WL_CONTROLPLANE_IP"], "10.0.0.170")
        self.assertEqual(plan["MGMT_LB_RANGE"], "10.0.0.171-10.0.0.184")
        self.assertEqual(plan["WL_LB_RANGE"], "10.0.0.185-10.0.0.198")
        self.assertEqual(json.loads(plan["IP_PLAN_ORIGINAL_POOLS"]), [{"range": "10.0.0.100 10.0.0.200"}])
        self.assertEqual(json.loads(plan["IP_PLAN_ORIGINAL_DHCP"]), {"domain_name_server_list": ["8.8.8.8"]})
        self.assertEqual(plan["DNS_VM_IP"], "10.0.0.5")
        self.assertTrue(os.path.exists(os.path.join(self.cache, "pc-vms.json")))
        self.assertEqual(oct(os.stat(os.path.join(self.cache, "pc-vms.json")).st_mode & 0o777), "0o600")

    def test_ip_plan_no_pool(self):
        self.fake.subnet["spec"]["resources"]["ip_config"]["pool_list"] = []
        self.assertEqual(run("pc", "ip-plan", "sub-1", "--no-ping")[0], 3)

    def test_ip_plan_too_small(self):
        self.assertEqual(run("pc", "ip-plan", "sub-1", "--no-ping", "--reserve", "95")[0], 4)

    def test_subnet_set_and_restore(self):
        dhcp = 'merge:{"domain_name_server_list":["10.0.0.5"],"domain_name":"ntnxlab.local"}'
        rc, out, _ = run("pc", "subnet-set", "sub-1", "--pools", "10.0.0.100-10.0.0.168", "--dhcp", dhcp)
        self.assertEqual((rc, out.strip()), (0, "10.0.0.100-10.0.0.168"))
        ipc = self.fake.puts[-1]["spec"]["resources"]["ip_config"]
        self.assertEqual(ipc["dhcp_options"], {"domain_name_server_list": ["10.0.0.5"], "domain_name": "ntnxlab.local"})
        self.assertEqual(self.fake.puts[-1]["metadata"]["spec_version"], 3)
        orig = json.dumps([{"range": "10.0.0.100 10.0.0.200"}])
        rc, out, _ = run("pc", "subnet-set", "sub-1", "--pools-json", orig, "--dhcp", "unset")
        self.assertEqual(out.strip(), "10.0.0.100-10.0.0.200")
        self.assertNotIn("dhcp_options", self.fake.puts[-1]["spec"]["resources"]["ip_config"])
        run("pc", "subnet-set", "sub-1", "--pools-json", orig, "--dhcp", 'set:{"domain_name_server_list":["8.8.8.8"]}')
        self.assertEqual(self.fake.puts[-1]["spec"]["resources"]["ip_config"]["dhcp_options"],
                         {"domain_name_server_list": ["8.8.8.8"]})

    def test_subnet_set_retries_failed_task(self):
        os.environ["NKP_RETRY_SLEEP"] = "0"
        self.fake.fail_tasks = 1
        orig = json.dumps([{"range": "10.0.0.100 10.0.0.200"}])
        rc, out, err = run("pc", "subnet-set", "sub-1", "--pools-json", orig, "--dhcp", "keep")
        self.assertEqual((rc, out.strip()), (0, "10.0.0.100-10.0.0.200"))
        self.assertIn("FAILED: IP 10.0.0.170 is in use Retrying", err)
        self.fake.fail_tasks = 3
        rc, _, err = run("pc", "subnet-set", "sub-1", "--pools-json", orig, "--dhcp", "keep")
        self.assertNotEqual(rc, 0)
        self.assertEqual(err.count("Retrying"), 2)
        self.assertIn("FAILED: IP 10.0.0.170 is in use", err.splitlines()[-1])

    def test_capacity(self):
        c = kv(run("pc", "capacity", "pe-1", "default")[1])
        self.assertEqual((c["HOSTS"], c["CORES"], c["HOST_MEM_GIB"]), ("3", "96", "1536"))
        self.assertEqual((c["VM_VCPU"], c["VM_MEM_GIB"], c["VMS_OK"]), ("4", "8", "Y"))
        self.assertEqual(c["SC_FREE_GIB"], "600")

    def test_password_not_in_argv_or_output(self):
        rc, out, err = run("pc", "clusters")
        self.assertNotIn("secret", out + err)


class Harbor(ServerTest):
    def test_ping_project(self):
        self.assertEqual(run("harbor", "ping")[0], 0)
        self.assertEqual(run("harbor", "ensure-project", "nkp")[0], 0)
        self.assertEqual(run("harbor", "ensure-project", "other")[0], 0)
        self.assertIn("other", self.fake.projects)
        self.assertEqual(run("harbor", "repos", "nkp")[1].strip(), "3")
        self.assertEqual(run("harbor", "public", "nkp")[0], 1)
        self.fake.projects["nkp"]["metadata"]["public"] = "true"
        self.assertEqual(run("harbor", "public", "nkp")[0], 0)

    def test_robot_replaces_and_scopes(self):
        rc, out, _ = run("harbor", "robot", "nkp-wl1", "--project", "nkp", "--description", "x")
        self.assertEqual((rc, out), (0, "robot$nkp-wl1\ts3cr3t\n"))
        self.assertEqual(self.fake.deleted, [7])
        perm = self.fake.created_robot["permissions"][0]
        self.assertEqual((perm["namespace"], perm["access"]), ("nkp", [{"resource": "repository", "action": "pull"}]))

    def test_wrong_password(self):
        os.environ["NKP_HARBOR_PASSWORD"] = "nope"
        self.assertNotEqual(run("harbor", "ensure-project", "nkp")[0], 0)
        self.assertNotEqual(run("harbor", "whoami")[0], 0)

    def test_ping_without_password(self):
        os.environ["NKP_HARBOR_PASSWORD"] = ""
        self.assertEqual(run("harbor", "ping")[0], 0)
        self.assertNotEqual(run("harbor", "whoami")[0], 0)

    def test_whoami(self):
        self.assertEqual(run("harbor", "whoami")[1], "admin\n")


class Pure(unittest.TestCase):
    def test_ip_ops(self):
        ok = lambda *a: run("ip", *a)[0] == 0  # noqa: E731
        self.assertTrue(ok("ip", "10.0.0.1"))
        self.assertFalse(ok("ip", "10.0.0.256"))
        self.assertTrue(ok("cidr", "10.0.0.0/24"))
        self.assertFalse(ok("cidr", "10.0.0.0"))
        self.assertFalse(ok("range", "10.0.0.9-10.0.0.1"))
        self.assertTrue(ok("range_in_cidr", "10.0.0.1-10.0.0.9", "10.0.0.0/24"))
        self.assertTrue(ok("ip_in_ranges", "10.0.0.5", "10.0.1.0-10.0.1.9,10.0.0.1-10.0.0.9"))
        self.assertTrue(ok("range_in_ranges", "10.0.0.2-10.0.0.3", "10.0.0.1-10.0.0.9"))
        self.assertFalse(ok("range_in_ranges", "10.0.0.2-10.0.0.30", "10.0.0.1-10.0.0.9"))
        self.assertTrue(ok("range_overlaps", "10.0.0.9-10.0.0.20", "10.0.0.1-10.0.0.9"))
        self.assertFalse(ok("range_overlaps", "10.0.0.10-10.0.0.20", ""))
        self.assertTrue(ok("cidr_overlap", "10.0.0.0/16", "10.0.5.0/24"))
        self.assertEqual(run("ip", "range_first", "10.0.0.7-10.0.0.9")[1], "10.0.0.7\n")

    def test_ip_select_minimum(self):
        self.assertIsNone(nkp_lab.ip_select("10.0.0.1-10.0.0.11", set(), 30, 12, 0))
        plan = nkp_lab.ip_select("10.0.0.1-10.0.0.12", set(), 30, 12, 0)
        self.assertEqual(plan["IP_PLAN_NEW_POOLS"], "")
        self.assertEqual(plan["WL_LB_RANGE"], "10.0.0.8-10.0.0.12")

    def test_cert_covers(self):
        sans = (("DNS", "*.lab.local"), ("IP Address", "10.0.0.20"))
        self.assertTrue(nkp_lab.cert_covers(sans, "pc.lab.local"))
        self.assertFalse(nkp_lab.cert_covers(sans, "a.pc.lab.local"))
        self.assertTrue(nkp_lab.cert_covers(sans, "10.0.0.20"))
        self.assertFalse(nkp_lab.cert_covers(sans, "10.0.0.21"))

    def test_reserved_ranges(self):
        clusters = [{"spec": {"controlPlaneEndpoint": {"host": "10.0.0.169"},
                              "topology": {"variables": [{"value": {"addons": {"serviceLoadBalancer": {
                                  "configuration": {"addressRanges": [{"start": "10.0.0.171", "end": "10.0.0.184"}]}}}}}]}}},
                    {"spec": {"controlPlaneEndpoint": {"host": "api.lab"}}}]
        self.assertEqual(nkp_lab.reserved_ranges(clusters), "10.0.0.169-10.0.0.169,10.0.0.171-10.0.0.184")

    def test_kv_and_private_file(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            nkp_lab.kv(A="x=y", B=[1], C=None)
        self.assertEqual(out.getvalue(), "A=x=y\nB=[1]\nC=\n")
        with self.assertRaises(ValueError):
            nkp_lab.kv(A="a\nb")
        d = tempfile.mkdtemp()
        p = os.path.join(d, "f")
        nkp_lab.write_private(p, "s")
        self.assertEqual(os.stat(p).st_mode & 0o777, 0o600)

    def test_harbor_values(self):
        self.assertEqual(nkp_lab.harbor_project_of("https://h:5000/nkp/sub"), "nkp")
        self.assertEqual(nkp_lab.harbor_project_of("https://h:5000"), "")
        ceph = nkp_lab.ceph_override(8)["cephClusterSpec"]["storage"]["storageClassDeviceSets"][0]
        self.assertEqual((ceph["count"], ceph["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"]), (8, "40Gi"))
        ad = nkp_lab.appdeployment("harbor", "kommander", "harbor-2.14.1", "harbor-overrides")
        self.assertEqual(ad["spec"], {"appRef": {"name": "harbor-2.14.1", "kind": "ClusterApp"},
                                      "configOverrides": {"name": "harbor-overrides"}})


class KubeMock(unittest.TestCase):
    """k8s commands against a kubectl stub that serves JSON files."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        stub = os.path.join(self.dir, "kubectl")
        with open(stub, "w") as f:
            f.write("#!/bin/sh\nexec python3 %r \"$@\"\n" % os.path.join(self.dir, "stub.py"))
        os.chmod(stub, 0o755)
        with open(os.path.join(self.dir, "stub.py"), "w") as f:
            f.write(STUB)
        self.path = os.environ["PATH"]
        os.environ["PATH"] = self.dir + os.pathsep + self.path
        os.environ["STUB_DIR"] = self.dir

    def tearDown(self):
        os.environ["PATH"] = self.path

    def put(self, key, obj):
        with open(os.path.join(self.dir, key.replace("/", "%") + ".json"), "w") as f:
            json.dump(obj, f)

    def test_clusters_unreachable_fails(self):
        self.assertNotEqual(run("k8s", "clusters", "--kubeconfig", "k")[0], 0)
        self.put("get_clusters.cluster.x-k8s.io_-A", {"items": [{"metadata": {"namespace": "default", "name": "m"}}]})
        self.assertEqual(run("k8s", "clusters", "--kubeconfig", "k")[1], "default\tm\n")

    def test_hr_not_ready(self):
        self.put("get_-n_kommander_helmreleases.helm.toolkit.fluxcd.io", {"items": []})
        self.assertEqual(run("k8s", "hr-not-ready", "kommander", "--kubeconfig", "k")[0], 1)
        self.put("get_-n_kommander_helmreleases.helm.toolkit.fluxcd.io", {"items": [
            {"metadata": {"name": "a"}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}},
            {"metadata": {"name": "b"}, "status": {"conditions": [{"type": "Ready", "status": "False", "message": "x\ny"}]}}]})
        self.assertEqual(run("k8s", "hr-not-ready", "kommander", "--kubeconfig", "k")[1], "b\tx y\n")

    def test_ncr(self):
        pem = "-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\n"
        self.put("get_-n_kommander_kommanderclusters_-l_kommander.d2iq.io%host=true", {"items": [
            {"status": {"ingress": {"address": "10.0.0.171", "caBundle": base64.b64encode(pem.encode()).decode()}}}]})
        ca = os.path.join(self.dir, "ca.pem")
        rc, out, _ = run("k8s", "ncr", "--kubeconfig", "k", "--ca-out", ca)
        self.assertEqual(kv(out), {"NCR_HOST": "10.0.0.171", "NCR_PRESENT": "N", "NCR_CA_FOUND": "Y"})
        with open(ca) as f:
            self.assertEqual(f.read(), pem)
        self.assertEqual(os.stat(ca).st_mode & 0o777, 0o600)
        self.put("-n_ncr-system_get_secret_harbor-admin-password",
                 {"data": {"HARBOR_ADMIN_PASSWORD": base64.b64encode(b"pw").decode()}})
        self.assertEqual(kv(run("k8s", "ncr", "--kubeconfig", "k")[1])["NCR_PRESENT"], "Y")
        self.assertEqual(run("k8s", "harbor-password", "--kubeconfig", "k")[1], "pw\n")

    def test_workspaces(self):
        self.put("get_workspaces.workspaces.kommander.mesosphere.io", {"items": [
            {"metadata": {"name": "default-workspace"}, "status": {"namespaceRef": {"name": "kommander-default-workspace"}}},
            {"metadata": {"name": "x"}, "spec": {"namespaceName": "x"}}, {"metadata": {"name": "broken"}}]})
        self.assertEqual(run("k8s", "workspaces", "--kubeconfig", "k")[1],
                         "default-workspace\tkommander-default-workspace\nx\tx\n")

    def test_harbor_prereqs(self):
        self.put("get_clusterapps.apps.kommander.d2iq.io", {"items": [
            {"metadata": {"name": "cloudnative-pg-1.25.1"}}, {"metadata": {"name": "harbor-2.14.1"}}]})
        self.put("-n_kommander_get_appdeployments.apps.kommander.d2iq.io_rook-ceph-cluster",
                 {"spec": {"configOverrides": {"name": "my-ceph"}}})
        self.assertEqual(kv(run("k8s", "harbor-prereqs", "--kubeconfig", "k")[1]), {
            "CNPG_APP": "cloudnative-pg-1.25.1", "HARBOR_APP": "harbor-2.14.1", "ROOK_ENABLED": "Y",
            "ROOK_OVERRIDES": "my-ceph", "OBJECT_STORE": "N", "NCR_HOST": "", "NCR_PRESENT": "N"})

    def test_cluster_app_newest(self):
        self.put("get_clusterapps.apps.kommander.d2iq.io", {"items": [
            {"metadata": {"name": n}} for n in ("harbor-2.9.0", "harbor-2.14.1", "harbor-operator-1.0", "cloudnative-pg-1.25.1")]})
        self.assertEqual(nkp_lab.cluster_app(nkp_lab.Kube("k"), "harbor"), "harbor-2.14.1")
        self.assertEqual(nkp_lab.cluster_app(nkp_lab.Kube("k"), "rook-ceph-cluster"), "")


STUB = r'''
import json, os, sys
args = sys.argv[1:]
args = args[2:] if args[:1] == ["--kubeconfig"] else args
if args[-2:] == ["-o", "json"]:
    args = args[:-2]
key = "_".join(args).replace("/", "%")
path = os.path.join(os.environ["STUB_DIR"], key + ".json")
if os.path.exists(path):
    sys.stdout.write(open(path).read())
    sys.exit(0)
sys.stderr.write("Error from server (NotFound): " + key + "\n")
sys.exit(1)
'''

if __name__ == "__main__":
    unittest.main()
