#!/usr/bin/env bash
# --lab --unattended end to end: real nkp_lab.py, fake Prism Central/Harbor (TLS), kubectl stub; nkp and docker
# mocked (bash 4+). Prints what each phase did; exits 1 if a phase failed, errored or wrote a secret to a file.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fake_lab
. "$S" || true
trap - INT
WORKDIR=$(mktemp -d "$T2/lab.XXXX")
HOME=$WORKDIR
export KSTATE="$WORKDIR/k"; mkdir -p "$KSTATE"
rm -f "$T2/port" "$T2/state"
FAKE_REPOS=0 python3 "$T2/fakeserver.py" "$T2/port" "$T2/state" 2>"$WORKDIR/server.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 50); do [[ -s $T2/port ]] && break; command sleep 0.1; done
PORT=$(cat "$T2/port") NCR_PORT=$(cat "$T2/port")
kput() { python3 -c 'import json,sys,os; open(os.path.join(os.environ["KSTATE"], sys.argv[1].replace("/","%")+".json"),"w").write(sys.argv[2])' "$1" "$2"; }
READY='{"items":[{"metadata":{"name":"x"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
kput "get_-n_kommander_helmreleases.helm.toolkit.fluxcd.io" "$READY"
kput "get_-n_kommander-default-workspace_helmreleases.helm.toolkit.fluxcd.io" "$READY"
kput "get_-n_kommander_kommanderclusters_-l_kommander.d2iq.io/host=true" \
  "{\"items\":[{\"status\":{\"ingress\":{\"address\":\"127.0.0.1\",\"caBundle\":\"$(base64 <"$T2/cert.pem" | tr -d '\n')\"}}}]}"
kput "get_namespace_kube-system" '{"metadata":{"uid":"uid-1"}}'
kput "get_clusterapps.apps.kommander.d2iq.io" '{"items":[{"metadata":{"name":"cloudnative-pg-1.25.1"}},{"metadata":{"name":"harbor-2.14.1"}},{"metadata":{"name":"rook-ceph-1.17.0"}},{"metadata":{"name":"rook-ceph-cluster-1.17.0"}},{"metadata":{"name":"kube-prometheus-stack-69.0.0"}}]}'
kput "-n_kommander_get_appdeployments.apps.kommander.d2iq.io_rook-ceph-cluster" '{"spec":{"appRef":{"name":"rook-ceph-cluster-1.17.0","kind":"ClusterApp"}}}'

mkdir -p "$HOME/.ssh" && echo "ssh-ed25519 AAAA test" >"$HOME/.ssh/id_ed25519.pub"
CI=$HOME/nkp-dist/nkp-bundle_v2.19.0_linux_amd64/nkp-v2.19.0/container-images
mkdir -p "$CI" && touch "$CI"/{konvoy-image-bundle,kommander-image-bundle,nkp-release-specs}-v2.19.0.tar \
  "$CI/nkp-ai-applications-catalog-image-bundle-2.19.tar" "$CI/nkp-nutanix-product-catalog-image-bundle-2.19.tar"
cd "$WORKDIR" && init_config >/dev/null 2>&1
sedi -e "s|^NUTANIX_ENDPOINT=.*|NUTANIX_ENDPOINT=127.0.0.1:${PORT}|" -e 's|^SUBNET=.*|SUBNET=primary|' nkp-lab.env
CONFIG_FILE=$WORKDIR/nkp-lab.env UNATTENDED=1 LAB=1 FORCE_INSECURE=1
export NUTANIX_PASSWORD=secret TMUX=1
unset NUTANIX_REGISTRY_PASSWORD REGISTRY_MIRROR_PASSWORD
C_B="" C_G="" C_Y="" C_R="" C_C="" C_0=""

docker() { case $1 in info) return 0 ;; login) cat >/dev/null; return 0 ;; esac; }
nkp() {
  echo "nkp $*" >>"$WORKDIR/calls"
  case "$1 $2" in
    "create cluster")
      if [[ "$*" == *--help* ]]; then echo "  --nutanix-registry-username string  --bundle strings  --registry-mirror-url string"; return 0; fi
      if [[ "$*" == *--dry-run* ]]; then echo "kind: Cluster"; return 0; fi
      local n a; for a in "$@"; do [[ $a == --cluster-name=* ]] && n=${a#*=}; done
      mkdir -p "$WORKDIR/$n" && echo "kubeconfig" >"$WORKDIR/$n/$n.conf" ;;
    "get dashboard") printf 'Username: u\nPassword: p\nURL: https://10.0.0.171/dkp/kommander/dashboard\n' ;;
  esac
}
bash() { echo "child: NKP_LAB_CHILD=${NKP_LAB_CHILD:-} $*" >>"$WORKDIR/calls"; }
sleep() { :; }
date() { if [[ ${1-} == -Is ]]; then command date +%FT%T%z; else command date "$@"; fi; }

phase_lab 2>"$WORKDIR/err"; lab_rc=$?
echo "phase_lab rc=$lab_rc"
trap - ERR; set +e
grep -E 'ERROR|unbound|Traceback' "$WORKDIR/err"
echo "--- mgmt create:"; grep -- '--self-managed' "$WORKDIR/calls" | grep -v -e dry-run -e --help | head -1 | tr ' ' '\n' \
  | grep -E 'cluster-name|control-plane-endpoint-ip|load-balancer|subnets=|storage|image=|ntp|insecure|registry|bundle' | sort -u
echo "--- Harbor objects:"; python3 -c 'import json,sys; print(" ".join(o["kind"]+"/"+o["metadata"]["name"] for o in map(json.loads, open(sys.argv[1]))))' "$KSTATE/applied"
echo "--- push:"; grep 'push bundle' "$WORKDIR/calls" | sed 's/--to-registry-password=[^ ]*/--to-registry-password=<hidden>/'
echo "--- marker:"; cat "$WORKDIR/nkp-mgmt/harbor-push.env"
echo "--- child:"; grep child "$WORKDIR/calls"
echo "--- PUT pools:"; python3 -c 'import json; s=json.load(open("'"$T2"'/state")); print(s["puts"][-1]["spec"]["resources"]["ip_config"]["pool_list"])'
echo "--- stderr tail:"; tail -25 "$WORKDIR/err"

echo "=== child workload run"
unset -f bash
WORKLOAD=1 LAB=0 CONFIG_FILE="" UNATTENDED=1 TMUX_SESSION=nkp-workload
CLUSTER_NAME="" SIZING="" WORKSPACE_NAMESPACE="" CONTROLPLANE_IP="" SERVICE_LB_IP_RANGE=""
kput "get_clusters.cluster.x-k8s.io_-A" "{\"items\":[{\"metadata\":{\"namespace\":\"default\",\"name\":\"nkp-mgmt\"},\"spec\":{\"controlPlaneEndpoint\":{\"host\":\"$(. "$WORKDIR/nkp-install.env"; echo "$CONTROLPLANE_IP")\"}}}]}"
kput "get_nodes" '{"items":[{"status":{"nodeInfo":{"kubeletVersion":"v1.36.2"}}}]}'
kput "get_workspaces.workspaces.kommander.mesosphere.io" '{"items":[{"metadata":{"name":"default-workspace"},"spec":{"namespaceName":"kommander-default-workspace"}}]}'
rm -f "$WORKDIR/calls"
phase_workload 2>"$WORKDIR/err2"; wl_rc=$?
echo "phase_workload rc=$wl_rc"
grep -E 'ERROR|unbound|Traceback' "$WORKDIR/err2"
grep 'create cluster nutanix' "$WORKDIR/calls" | grep -v -e --dry-run -e --help | tr ' ' '\n' \
  | grep -E 'namespace|kubeconfig|cluster-name|endpoint-ip|load-balancer|self-managed|registry|bundle' | sed 's/password=.*/password=<hidden>/'
grep -E 'Workspace|Capacity|Memory|Images|robot|Harbor' "$WORKDIR/err2"
echo "--- create-cluster.cmd (workload):"; grep -E 'mirror' "$WORKDIR/nkp-workload1/create-cluster.cmd"
echo "--- secrets in answers/summary files:"; grep -lE 's3cr3t|=secret' "$WORKDIR"/*.env "$WORKDIR"/nkp-mgmt/*.env 2>/dev/null || echo none
bad=$(grep -hE 'ERROR|unbound|Traceback' "$WORKDIR/err" "$WORKDIR/err2"; grep -lE 's3cr3t|=secret' "$WORKDIR"/*.env "$WORKDIR"/nkp-mgmt/*.env 2>/dev/null)
if ((lab_rc == 0 && wl_rc == 0)) && [[ -z $bad ]]; then echo "lab-e2e: --lab and --workload completed"; else echo "lab-e2e: FAILED"; exit 1; fi
