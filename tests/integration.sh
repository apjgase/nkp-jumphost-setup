#!/usr/bin/env bash
# Shell <-> nkp_lab.py tests: real nkp_lab.py, fake Prism Central/Harbor over TLS, kubectl stub (bash 4+).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fake_lab
: >"$T2/results"
check() {
  local name=$1; shift
  if "$@"; then echo ok >>"$T2/results"; echo "  ok   $name"; else echo FAIL >>"$T2/results"; echo "  FAIL $name"; fi
}
eq() { [[ $1 == "$2" ]] || { echo "       got '$1' want '$2'" >&2; return 1; }; }
has() { grep -qF -- "$2" "$1" || { echo "       '$2' not in $1" >&2; return 1; }; }
hasnt() { ! grep -qF -- "$2" "$1" || { echo "       '$2' unexpectedly in $1" >&2; return 1; }; }
state() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$T2/state" "$1"; }

setup() { # [repos] [public]
  . "$S" || true
  trap - ERR INT
  set +e +u
  C_B="" C_G="" C_Y="" C_R="" C_C="" C_0=""
  WORKDIR=$(mktemp -d "$T2/wd.XXXX")
  export KSTATE="$WORKDIR/k"; mkdir -p "$KSTATE"
  rm -f "$T2/port" "$T2/state"
  FAKE_REPOS=${1:-3} FAKE_PUBLIC=${2:-false} python3 "$T2/fakeserver.py" "$T2/port" "$T2/state" 2>"$WORKDIR/server.log" &
  SRV=$!
  for _ in $(seq 50); do [[ -s $T2/port ]] && break; sleep 0.1; done
  PORT=$(cat "$T2/port")
  NUTANIX_ENDPOINT="https://127.0.0.1:${PORT}" NUTANIX_USER=admin NUTANIX_PASSWORD=secret PC_TLS=insecure UNATTENDED=1
  NCR_PORT=$PORT
  trap 'kill $SRV 2>/dev/null' EXIT
}
kput() { python3 -c 'import json,sys,os; open(os.path.join(os.environ["KSTATE"], sys.argv[1].replace("/","%")+".json"),"w").write(sys.argv[2])' "$1" "$2"; }
ncr_cluster() { # [harbor present]
  kput "get_-n_kommander_kommanderclusters_-l_kommander.d2iq.io/host=true" \
    "{\"items\":[{\"status\":{\"ingress\":{\"address\":\"127.0.0.1\",\"caBundle\":\"$(base64 <"$T2/cert.pem" | tr -d '\n')\"}}}]}"
  kput "get_namespace_kube-system" '{"metadata":{"uid":"uid-1"}}'
  if [[ ${1:-Y} == Y ]]; then
    kput "-n_ncr-system_get_secret_harbor-admin-password" "{\"data\":{\"HARBOR_ADMIN_PASSWORD\":\"$(printf secret | base64)\"}}"
  fi
  mkdir -p "$WORKDIR/nkp-mgmt"; MGMT_KCFG="$WORKDIR/nkp-mgmt/nkp-mgmt.conf"; : >"$MGMT_KCFG"
}
nkp() {
  echo "nkp $*" >>"$WORKDIR/nkp.calls"
  case "$*" in *--help*) echo "--bundle --registry-mirror-url" ;; esac
}

echo "== Prism Central inventory, IP plan, subnet, capacity"
(
  setup
  PC_API_OK=1 NUTANIX_CLUSTER=PE1 SUBNET=primary VM_IMAGE=nkp-rocky-9.6-release-1.36.2 STORAGE_CONTAINER_NAME=default
  q_inventory 2>"$WORKDIR/err"
  check "PE uuid" eq "$PE_UUID" pe-1
  check "subnet uuid / cidr / pool" eq "$SUBNET_UUID $NODE_CIDR $NODE_POOLS" "sub-1 10.0.0.0/24 10.0.0.100-10.0.0.200"
  PC_HOST=127.0.0.1 NO_IP_PLAN=0
  lab_network 2>"$WORKDIR/err"
  f=$(ip_plan_file)
  check "plan block" eq "$(ip_plan_get IP_PLAN_BLOCK)" "10.0.0.169-10.0.0.198"
  check "plan file mode 600" eq "$(mode "$f")" 600
  check "original pools kept as JSON" eq "$(ip_plan_get IP_PLAN_ORIGINAL_POOLS)" '[{"range":"10.0.0.100 10.0.0.200"}]'
  check "PUT pools" eq "$(state 's["puts"][-1]["spec"]["resources"]["ip_config"]["pool_list"]')" \
    "[{'range': '10.0.0.100 10.0.0.168'}, {'range': '10.0.0.199 10.0.0.200'}]"
  check "DNS VM found, but not answering: DHCP kept" eq "$(state 's["puts"][-1]["spec"]["resources"]["ip_config"]["dhcp_options"]')" \
    "{'domain_name_server_list': ['8.8.8.8']}"
  check "warned about DNS" has "$WORKDIR/err" "does not resolve ntnxlab.local"
  check "NODE_POOLS updated" eq "$NODE_POOLS" "10.0.0.100-10.0.0.168,10.0.0.199-10.0.0.200"
  check "VM list cached 600" eq "$(mode "$WORKDIR/cache/pc-vms.json")" 600
  check "no password in the process args" hasnt "$WORKDIR/err" "secret"
  n=$(state 'len(s["puts"])')
  lab_network 2>"$WORKDIR/err"
  check "rerun reuses the plan, no PUT" eq "$(state 'len(s["puts"])')" "$n"

  restore_subnet 2>"$WORKDIR/err"
  check "restore pools" eq "$(state 's["puts"][-1]["spec"]["resources"]["ip_config"]["pool_list"]')" "[{'range': '10.0.0.100 10.0.0.200'}]"
  check "restore without DNS change keeps DHCP" eq "$(state '"dhcp_options" in s["puts"][-1]["spec"]["resources"]["ip_config"]')" True
  printf 'IP_PLAN_DNS=10.0.0.5\nIP_PLAN_ORIGINAL_DHCP=null\n' >>"$f"
  restore_subnet 2>"$WORKDIR/err"
  check "restore with DNS change and no original DHCP removes it" eq "$(state '"dhcp_options" in s["puts"][-1]["spec"]["resources"]["ip_config"]')" False
  printf 'IP_PLAN_ORIGINAL_DHCP=%q\n' '{"domain_name_server_list":["1.1.1.1"]}' >>"$f"
  restore_subnet 2>"$WORKDIR/err"
  check "restore sets the original DHCP" eq "$(state 's["puts"][-1]["spec"]["resources"]["ip_config"]["dhcp_options"]')" "{'domain_name_server_list': ['1.1.1.1']}"

  BUNDLE_ARGS=(--bundle=x)
  capacity_check 7 44 176 2>"$WORKDIR/err"
  check "hosts row" has "$WORKDIR/err" "3: 96 cores, 1536 GiB memory"
  check "running VMs" has "$WORKDIR/err" "4 vCPU, 8 GiB"
  check "disk incl. Harbor Ceph volumes" has "$WORKDIR/err" "720 GiB disk (incl. 160 GiB of Rook Ceph volumes for Harbor)"
  check "storage warning" has "$WORKDIR/err" "has about 600 GiB free"
  check "memory ok" has "$WORKDIR/err" "Memory: 176 GiB needed"

  check "tls probe: self-signed = untrusted" eval 'py tls probe "$NUTANIX_ENDPOINT"; [[ $? == 1 ]]'
  fetch_server_cert "$WORKDIR/pc.pem"
  check "fetched cert covers 127.0.0.1" eval 'cert_covers_host "$WORKDIR/pc.pem" 127.0.0.1 >/dev/null'
  check "pc_status" eq "$(pc_status /api/nutanix/v3/users/me)" 200
  NUTANIX_PASSWORD=bad
  check "pc_status bad password" eq "$(pc_status /api/nutanix/v3/users/me)" 401
  check "ipcalc via python" eval 'ipcalc range_in_cidr 10.0.0.1-10.0.0.9 10.0.0.0/24 && ! ipcalc ip 1.2.3'
)

echo "== Harbor present, project has images: no push"
(
  setup 3
  ncr_cluster Y
  BUNDLE_FILES="/b/konvoy-image-bundle-v2.19.0.tar,/b/kommander-image-bundle-v2.19.0.tar"
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>"$WORKDIR/err"; rc=$?
  m=$(harbor_marker nkp-mgmt)
  check "rc 0" eq "$rc" 0
  check "already running" has "$WORKDIR/err" "Harbor is already running"
  check "nothing pushed" eval '! grep -q "push bundle" "$WORKDIR/nkp.calls" 2>/dev/null'
  check "marker url" eq "$(harbor_marker_get nkp-mgmt HARBOR_URL)" "https://127.0.0.1:${PORT}/nkp"
  check "marker records existing images" eq "$(harbor_marker_get nkp-mgmt PUSH_BUNDLES)" "existing (3 repositories)"
  check "marker 600, no password" eval '[[ $(mode "$m") == 600 ]] && ! grep -q "=secret" "$m"'
  check "CA written 600" eq "$(mode "$WORKDIR/nkp-mgmt/harbor-ca.pem")" 600
)

echo "== Harbor present, empty project: push, then skip on rerun"
(
  setup 0
  ncr_cluster Y
  BUNDLE_FILES="/b/konvoy-image-bundle-v2.19.0.tar,/b/kommander-image-bundle-v2.19.0.tar"
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>"$WORKDIR/err"
  push=$(grep 'push bundle' "$WORKDIR/nkp.calls")
  check "push both bundles" eq "$push" "nkp push bundle --bundle /b/konvoy-image-bundle-v2.19.0.tar --bundle /b/kommander-image-bundle-v2.19.0.tar --to-registry=https://127.0.0.1:${PORT}/nkp --to-registry-username=admin --to-registry-password=secret --to-registry-ca-cert-file=$WORKDIR/nkp-mgmt/harbor-ca.pem"
  check "displayed command masks the password" eval 'grep -q "to-registry-password=\\\\\*\\\\\*" "$WORKDIR/err" || grep -q "to-registry-password=\*\*" "$WORKDIR/err"'
  check "password not displayed" hasnt "$WORKDIR/err" "password=secret"
  check "marker records the bundles" eq "$(harbor_marker_get nkp-mgmt PUSH_BUNDLES)" "$BUNDLE_FILES"
  check "marker uid" eq "$(harbor_marker_get nkp-mgmt PUSH_UID)" uid-1
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>"$WORKDIR/err"
  check "rerun: no second push" eq "$(grep -c 'push bundle' "$WORKDIR/nkp.calls")" 1
  check "rerun message" has "$WORKDIR/err" "not pushing again"
  kput "get_namespace_kube-system" '{"metadata":{"uid":"uid-2"}}'
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>"$WORKDIR/err"
  check "new cluster (uid): pushes again" eq "$(grep -c 'push bundle' "$WORKDIR/nkp.calls")" 2
)

echo "== Harbor absent: deploy as in the guide"
(
  setup 0
  ncr_cluster N
  kput "get_clusterapps.apps.kommander.d2iq.io" '{"items":[{"metadata":{"name":"cloudnative-pg-1.25.1"}},{"metadata":{"name":"harbor-2.13.0"}},{"metadata":{"name":"harbor-2.14.1"}},{"metadata":{"name":"rook-ceph-1.17.0"}},{"metadata":{"name":"rook-ceph-cluster-1.17.0"}}]}'
  kput "-n_kommander_get_appdeployments.apps.kommander.d2iq.io_rook-ceph-cluster" '{"spec":{"appRef":{"name":"rook-ceph-cluster-1.17.0","kind":"ClusterApp"}}}'
  BUNDLE_FILES="/b/konvoy-image-bundle-v2.19.0.tar"
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>"$WORKDIR/err"; rc=$?
  check "rc 0" eq "$rc" 0
  applied=$(python3 -c 'import json,sys; print(" ".join(o["kind"]+"/"+o["metadata"]["name"] for o in map(json.loads, open(sys.argv[1]))))' "$KSTATE/applied")
  check "objects in order" eq "$applied" "AppDeployment/cloudnative-pg AppDeployment/rook-ceph ConfigMap/rook-ceph-cluster-overrides AppDeployment/rook-ceph-cluster ObjectBucketClaim/harbor-registry Secret/harbor-s3-credentials ConfigMap/harbor-overrides AppDeployment/harbor"
  check "newest harbor ClusterApp" has "$KSTATE/applied" '"appRef": {"name": "harbor-2.14.1"'
  check "ceph count 8" has "$KSTATE/applied" '\"count\": 8'
  check "pushed after deploy" eq "$(grep -c 'push bundle' "$WORKDIR/nkp.calls")" 1
)

echo "== Harbor absent with HARBOR_OVERRIDES_FILE"
(
  setup 0
  ncr_cluster N
  kput "get_clusterapps.apps.kommander.d2iq.io" '{"items":[{"metadata":{"name":"cloudnative-pg-1.25.1"}},{"metadata":{"name":"harbor-2.14.1"}},{"metadata":{"name":"rook-ceph-1.17.0"}},{"metadata":{"name":"rook-ceph-cluster-1.17.0"}}]}'
  printf 'persistence:\n  imageChartStorage:\n    type: s3\n' >"$WORKDIR/values.yaml"
  HARBOR_OVERRIDES_FILE="$WORKDIR/values.yaml" BUNDLE_FILES="/b/konvoy-image-bundle-v2.19.0.tar"
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>"$WORKDIR/err"
  check "no bucket claim" hasnt "$KSTATE/applied" ObjectBucketClaim
  check "values from the file" has "$KSTATE/applied" 'persistence:\n  imageChartStorage:'
  check "enabled rook operator" has "$WORKDIR/err" "Enabled rook-ceph-1.17.0"
  check "enabled rook cluster" has "$WORKDIR/err" "Enabled rook-ceph-cluster-1.17.0"
)

echo "== Workload registry: robot on the project"
(
  setup 0
  ncr_cluster Y
  BUNDLE_FILES="/b/konvoy-image-bundle-v2.19.0.tar"
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>/dev/null
  MGMT_CLUSTER_NAME=nkp-mgmt CLUSTER_NAME=nkp-wl1 MGMT_USE_BUNDLE=Y
  q_mgmt_registry 2>"$WORKDIR/err"
  check "use the registry" eq "$USE_MGMT_REGISTRY" Y
  check "args" eq "${REGISTRY_MIRROR_ARGS[*]}" "--registry-mirror-url=https://127.0.0.1:${PORT}/nkp --registry-mirror-cacert=$WORKDIR/nkp-mgmt/harbor-ca.pem --registry-mirror-username=robot\$nkp-wl1 --registry-mirror-password=s3cr3t"
  check "robot pull-only on nkp" eq "$(state 's["robot"]["permissions"]')" "[{'kind': 'project', 'namespace': 'nkp', 'access': [{'resource': 'repository', 'action': 'pull'}]}]"
  check "old robot replaced" eq "$(state 's["deleted"]')" "[7]"
  CMD=(nkp create cluster nutanix "${REGISTRY_MIRROR_ARGS[@]}")
  check "redacted" eval '[[ $(redacted_command) != *s3cr3t* ]]'
)

echo "== Workload registry: public project, anonymous"
(
  setup 0 true
  ncr_cluster Y
  BUNDLE_FILES="/b/konvoy-image-bundle-v2.19.0.tar"
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>/dev/null
  MGMT_CLUSTER_NAME=nkp-mgmt CLUSTER_NAME=nkp-wl1 MGMT_USE_BUNDLE=Y
  q_mgmt_registry 2>"$WORKDIR/err"
  check "anonymous" eq "$NCR_AUTH" anonymous
  check "no credentials" eq "${#REGISTRY_MIRROR_ARGS[@]}" 2
)

echo "== Workload registry: no push yet, offers the Harbor step; USE_MGMT_REGISTRY=N"
(
  setup 0
  ncr_cluster Y
  MGMT_CLUSTER_NAME=nkp-mgmt CLUSTER_NAME=nkp-wl1 MGMT_USE_BUNDLE=Y BUNDLE_FILES="/b/konvoy-image-bundle-v2.19.0.tar"
  q_mgmt_registry 2>"$WORKDIR/err"
  check "ran the Harbor step" eq "$(grep -c 'push bundle' "$WORKDIR/nkp.calls")" 1
  check "then uses it" eq "$USE_MGMT_REGISTRY" Y
  rm -f "$(harbor_marker nkp-mgmt)"
  USE_MGMT_REGISTRY=N
  q_mgmt_registry 2>"$WORKDIR/err"
  check "N: internet, no push" eval '[[ $USE_MGMT_REGISTRY == N && ${#REGISTRY_MIRROR_ARGS[@]} == 0 && $(grep -c "push bundle" "$WORKDIR/nkp.calls") == 1 ]]'
)

echo "== External registry (REGISTRY_MIRROR_URL)"
(
  setup 0
  ncr_cluster N
  REGISTRY_MIRROR_URL="https://127.0.0.1:${PORT}/nkp" REGISTRY_MIRROR_USERNAME=admin REGISTRY_MIRROR_PASSWORD=secret
  REGISTRY_MIRROR_CACERT="$T2/cert.pem" BUNDLE_FILES="/b/konvoy-image-bundle-v2.19.0.tar"
  harbor_step nkp-mgmt "$MGMT_KCFG" 2>"$WORKDIR/err"
  check "no Harbor deployed" eval '[[ ! -f $KSTATE/applied ]]'
  check "pushed with the given CA" has "$WORKDIR/nkp.calls" "--to-registry-ca-cert-file=$T2/cert.pem"
  check "marker external" eq "$(harbor_marker_get nkp-mgmt HARBOR_EXTERNAL)" Y
  MGMT_CLUSTER_NAME=nkp-mgmt CLUSTER_NAME=nkp-wl1 MGMT_USE_BUNDLE=Y
  q_mgmt_registry 2>"$WORKDIR/err"
  check "robot on external" eq "${REGISTRY_MIRROR_ARGS[*]}" "--registry-mirror-url=https://127.0.0.1:${PORT}/nkp --registry-mirror-cacert=$T2/cert.pem --registry-mirror-username=robot\$nkp-wl1 --registry-mirror-password=s3cr3t"
)

echo "== Kubernetes helpers"
(
  setup
  ncr_cluster Y
  kput "get_clusters.cluster.x-k8s.io_-A" '{"items":[{"metadata":{"namespace":"default","name":"nkp-mgmt"},"spec":{"controlPlaneEndpoint":{"host":"10.0.0.169"}}},{"metadata":{"namespace":"ws1","name":"nkp-wl1"}}]}'
  kput "get_nodes" '{"items":[{"status":{"nodeInfo":{"kubeletVersion":"v1.36.2"}}}]}'
  printf 'CLUSTER_NAME=nkp-mgmt\nCONTROLPLANE_IP=10.0.0.169\nSERVICE_LB_IP_RANGE=10.0.0.171-10.0.0.184\nUSE_BUNDLE=Y\n' >"$WORKDIR/nkp-install.env"
  load_mgmt_context 2>"$WORKDIR/err"
  check "reserved ranges" eq "$RESERVED_RANGES" "10.0.0.169-10.0.0.169,10.0.0.171-10.0.0.184"
  check "k8s hint" eq "$K8S_VERSION_HINT" 1.36
  check "existing workload name rejected" eval '! v_workload_name nkp-wl1 2>/dev/null && v_workload_name nkp-wl2'
  kput "get_-n_kommander_helmreleases.helm.toolkit.fluxcd.io" '{"items":[{"metadata":{"name":"a"},"status":{"conditions":[{"type":"Ready","status":"False","message":"boom"}]}}]}'
  check "helmreleases_not_ready" eq "$(helmreleases_not_ready "$MGMT_KCFG" kommander)" $'a\tboom'
  kput "get_workspaces.workspaces.kommander.mesosphere.io" '{"items":[{"metadata":{"name":"default-workspace"},"status":{"namespaceRef":{"name":"kommander-default-workspace"}}}]}'
  WORKSPACE_NAMESPACE=newws CLUSTER_NAME=nkp-wl2
  q_workspace 2>"$WORKDIR/err"
  check "workspace created through python" has "$KSTATE/applied" '"kind": "Workspace", "metadata": {"name": "newws"'
  rm -f "$KSTATE/get_clusters.cluster.x-k8s.io_-A.json"
  check "unreachable cluster list fails" eval '! py k8s clusters --kubeconfig "$MGMT_KCFG" 2>/dev/null'
)

check_env() { # config for --check against the fake lab
  HOME=$WORKDIR
  mkdir -p "$HOME/.ssh" && echo "ssh-ed25519 AAAA t" >"$HOME/.ssh/id_ed25519.pub"
  CI=$HOME/nkp-dist/nkp-bundle_v2.19.0_linux_amd64/nkp-v2.19.0/container-images
  mkdir -p "$CI" && touch "$CI"/{konvoy-image-bundle,kommander-image-bundle,nkp-release-specs}-v2.19.0.tar
  (cd "$WORKDIR" && init_config >/dev/null 2>&1)
  sedi -e "s|^NUTANIX_ENDPOINT=.*|NUTANIX_ENDPOINT=127.0.0.1:${PORT}|" -e 's|^SUBNET=.*|SUBNET=primary|' "$WORKDIR/nkp-lab.env"
  CONFIG_FILE=$WORKDIR/nkp-lab.env UNATTENDED=1 NUTANIX_PASSWORD=secret
  docker() { case $1 in info) return 0 ;; version) echo 27.4.0 ;; esac; }
  nkp() { case "$*" in version*) printf '%s: %s\n' catalog v0.11.1 diagnose v0.14.0 kommander v2.19.0 konvoy v2.19.0 mindthegap v1.24.0 nkp "${NKP_FAKE_VER:-v2.19.0}" ;; *"create cluster nutanix --help"*) echo "--bundle --registry-mirror-url" ;; *"push bundle --help"*) echo "--to-registry" ;; esac; }
  tmux() { :; }
}

echo "== --check: lab ready, nothing changed"
(
  setup 0
  check_env
  ( phase_check ) 2>"$WORKDIR/err"; rc=$?
  check "exit 0" eq "$rc" 0
  for want in "PASS  python3" "PASS  Self-test" "PASS  Bundle  " "PASS  nkp create flags" "WARN  Reachable, TLS" \
              "PASS  Login" "PASS  Prism Element" "PASS  Subnet" "PASS  Node image" "PASS  Storage container" \
              "PASS  NTP" "PASS  IP plan" "PASS  Memory" "SKIP  Management cluster"; do
    check "$want" eval 'grep -E "$(sed "s/  */ +/g" <<<"$want")" "$WORKDIR/err" >/dev/null'
  done
  check "nkp release from the nkp: line" eval 'grep -E "PASS +nkp CLI +v2.19.0$" "$WORKDIR/err" >/dev/null'
  check "pro sizing by default" eval 'grep -E "PASS +Management sizing +pro:" "$WORKDIR/err" >/dev/null'
  check "IP plan dry run shows the block" has "$WORKDIR/err" "would reserve 10.0.0.169-10.0.0.198"
  check "TLS untrusted is a warning" has "$WORKDIR/err" "certificate not trusted here"
  check "read-only: no subnet PUT" eq "$(state 'len(s["puts"])')" 0
  check "report 600" eq "$(mode "$WORKDIR/lab-check.txt")" 600
  check "no password in the report" hasnt "$WORKDIR/lab-check.txt" secret
)

echo "== --check: wrong password fails"
(
  setup 0
  check_env
  NUTANIX_PASSWORD=bad
  ( phase_check ) 2>"$WORKDIR/err"; rc=$?
  check "exit 1" eq "$rc" 1
  check "login FAIL listed" has "$WORKDIR/err" "- Login: HTTP 401"
  NUTANIX_PASSWORD=secret NKP_FAKE_VER=v2.18.1
  ( phase_check ) 2>"$WORKDIR/err"
  check "wrong nkp release fails" has "$WORKDIR/err" "nkp version reports v2.18.1; expected v2.19.x"
)

echo "== --check: subnet spelling, package not extracted"
(
  setup 0
  check_env
  rm -rf "$HOME/nkp-dist"
  head -c 2048 /dev/zero >"$HOME/nkp-air-gapped-bundle_v2.19.0_linux_amd64.tar.gz"
  sub() { sedi "s|^SUBNET=.*|SUBNET=$1|" "$WORKDIR/nkp-lab.env"; ( phase_check ) 2>"$WORKDIR/err"; }
  sub Primary
  check "case-only match warns" has "$WORKDIR/err" "SUBNET=Primary matches 'primary' only ignoring case; set SUBNET=primary"
  check "IP plan still runs" has "$WORKDIR/err" "would reserve"
  check "tarball found, not extracted" has "$WORKDIR/err" "nkp-air-gapped-bundle_v2.19.0_linux_amd64.tar.gz (0 GiB) is not extracted yet; --prereqs-only extracts it"
  sub prim
  check "prefix gives a hint" has "$WORKDIR/err" "'prim' not found on PE1; set SUBNET=primary;"
  sedi 's|^SIZING=.*|SIZING=starter|' "$WORKDIR/nkp-lab.env"
  ( phase_check ) 2>"$WORKDIR/err"; rc=$?
  check "starter management sizing fails" has "$WORKDIR/err" "- Management sizing: SIZING=starter (4 vCPU / 8 GiB workers) is too small"
  check "starter: exit 1" eq "$rc" 1
  sedi 's|^SIZING=.*|SIZING=pro|' "$WORKDIR/nkp-lab.env"
  sub ""
  check "blank picks primary" eval 'grep -E "PASS +Subnet +primary:" "$WORKDIR/err" >/dev/null'
)

echo "== --check: management cluster exists, external registry"
(
  setup 2
  check_env
  ncr_cluster N
  CLUSTER_NAME=nkp-mgmt
  kput "get_clusters.cluster.x-k8s.io_-A" '{"items":[{"metadata":{"namespace":"default","name":"nkp-mgmt"}}]}'
  kput "get_-n_kommander_helmreleases.helm.toolkit.fluxcd.io" '{"items":[{"metadata":{"name":"a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
  kput "get_clusterapps.apps.kommander.d2iq.io" '{"items":[{"metadata":{"name":"cloudnative-pg-1.25.1"}},{"metadata":{"name":"harbor-2.14.1"}}]}'
  printf 'REGISTRY_MIRROR_URL=https://127.0.0.1:%s/nkp\nREGISTRY_MIRROR_USERNAME=admin\nREGISTRY_MIRROR_CACERT=%s\n' "$PORT" "$T2/cert.pem" >>"$WORKDIR/nkp-lab.env"
  REGISTRY_MIRROR_PASSWORD=secret
  ( phase_check ) 2>"$WORKDIR/err"; rc=$?
  check "exit 0" eq "$rc" 0
  check "kubernetes API" has "$WORKDIR/err" "1 Cluster API clusters"
  check "platform apps ready" has "$WORKDIR/err" "all HelmReleases in kommander Ready"
  check "registry reachable with CA" has "$WORKDIR/err" "PASS  Registry reachable"
  check "registry login" has "$WORKDIR/err" "as admin"
  check "registry project" has "$WORKDIR/err" "nkp: 2 repositories"
  check "capacity counts only the workload" has "$WORKDIR/err" "workload (management cluster exists)"
  check "not pushed yet" has "$WORKDIR/err" "WARN  Bundle pushed"
  check "read-only: nothing applied" eval '[[ ! -f $KSTATE/applied ]]'
)

echo
echo "passed $(grep -c '^ok' "$T2/results") failed $(grep -c FAIL "$T2/results")"
! grep -q FAIL "$T2/results"
