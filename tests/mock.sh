#!/usr/bin/env bash
# Mock tests for nkp-jumphost-setup.sh: its functions with nkp, kubectl, py and Prism Central mocked (bash 4+).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$SCRATCH
dies() { ! ( eval "$1" ) >/dev/null 2>&1; }
: >"$T/results"
check() { # name condition...
  local name=$1; shift
  if "$@"; then echo ok >>"$T/results"; echo "  ok   $name"; else echo FAIL >>"$T/results"; echo "  FAIL $name"; fi
}
eq() { [[ $1 == "$2" ]] || { echo "       got '$1' want '$2'" >&2; return 1; }; }

setup() {
  # shellcheck disable=SC1090
  . "$S" || true
  trap - ERR INT
  WORKDIR=$(mktemp -d "$T/wd.XXXX")
  C_B="" C_G="" C_Y="" C_R="" C_C="" C_0=""
}

echo "== unattended prompts"
(
  setup; UNATTENDED=1
  X=abc; ask X "Thing" 2>/dev/null; check "ask keeps default" eq "$X" abc
  Y=""; ask Y "Opt" optional 2>/dev/null; check "ask optional blank" eq "$Y" ""
  check "ask missing dies" dies 'Z=""; ask Z Z'
  check "ask invalid dies" dies 'Z=x; ask Z Z v_int'
  check "ask_yn Y" ask_yn "q" Y 2>/dev/null
  check "ask_yn N" eval '! ask_yn q N 2>/dev/null'
  vals=(Primary Secondary); P=primary; pick P "Subnet" vals 2>/dev/null
  check "pick adopts exact case" eq "$P" Primary
  vals=(only); P=""; pick P "One" vals 2>/dev/null; check "pick single choice" eq "$P" only
  check "pick unknown dies" dies 'vals=(a b); P=c; pick P x vals'
  NUTANIX_PASSWORD=""; check "ask_secret needs env" dies 'ask_secret NUTANIX_PASSWORD pw'
  t=0; retry_guard t; check "retry_guard first pass" eq "$t" 1
  check "retry_guard second pass dies" dies 'retry_guard t'
)
(
  setup; UNATTENDED=0
  vals=(only); P=""; pick P "One" vals 2>/dev/null; check "interactive single choice auto-selected" eq "$P" only
  vals=(x Primary); S2=""; default_match S2 vals '^primary$'; check "default_match" eq "$S2" Primary
  vals=(SelfService default-container-123); C=""; default_match C vals '^default$'; default_match C vals '^default'
  check "default container fallback" eq "$C" default-container-123
)

echo "== no terminal: no tmux relaunch"
(
  setup; UNATTENDED=1; unset TMUX STY NKP_LAB_CHILD
  tmux() { echo "tmux $*" >>"$T/tmux.calls"; }
  ( ensure_tmux_session </dev/null >/dev/null 2>&1; echo reached >"$T/tmux.reached" )
  check "continues in place without a terminal" eq "$(cat "$T/tmux.reached" 2>/dev/null)" reached
  check "tmux not started" eq "$(grep -c new-session "$T/tmux.calls" 2>/dev/null || true)" ""
)

echo "== --init-config and --config"
(
  setup; cd "$T" && rm -f nkp-lab.env
  init_config 2>/dev/null
  check "template written mode 600" eq "$(mode nkp-lab.env)" 600
  check "template sources with expected values" eval '( . ./nkp-lab.env; [[ -z $SUBNET && $STORAGE_CONTAINER_NAME == default && $WL_CLUSTER_NAME == nkp-workload1 && -z $CONTROLPLANE_IP && $TLS_MODE == insecure ]] )'
  CONFIG_FILE=$T/nkp-lab.env; load_answers 2>/dev/null
  check "load_answers uses --config" eq "$CLUSTER_NAME/$LAB_DOMAIN" nkp-mgmt/ntnxlab.local
  CONTROLPLANE_IP=1.1.1.1 SIZING=pro; WL_SIZING=starter WL_LB_RANGE=2.2.2.2-2.2.2.3 WL_CONTROLPLANE_IP=""
  apply_wl
  check "apply_wl overrides non-empty only" eq "$CLUSTER_NAME $SIZING $SERVICE_LB_IP_RANGE $CONTROLPLANE_IP" "nkp-workload1 starter 2.2.2.2-2.2.2.3 1.1.1.1"
  CLUSTER_NAME=m WL_CLUSTER_NAME=w SERVICE_LB_IP_RANGE=a WL_LB_RANGE=b
  swap_wl; check "swap_wl" eq "$CLUSTER_NAME $WL_CLUSTER_NAME $SERVICE_LB_IP_RANGE $WL_LB_RANGE" "w m b a"
  swap_wl; check "swap_wl back" eq "$CLUSTER_NAME $SERVICE_LB_IP_RANGE" "m a"
)

echo "== remediation"
(
  setup; UNATTENDED=1; rm -f "$T/calls"
  STATE=$T/hrstate; echo bad >"$STATE"
  kubectl() { echo "kubectl $*" >>"$T/calls"; }
  py() {
    echo "py $*" >>"$T/calls"
    case "$1 $2" in
      "k8s starved-pods") if [[ $(cat "$STATE") == bad ]]; then echo kommander/dex-1; fi ;;
      "k8s md0") echo "default nkp-mgmt-md-0-abc 4" ;;
      "k8s hr-not-ready") if [[ $(cat "$STATE") == bad ]]; then printf 'dex\tfailed\n'; fi ;;
      "k8s hr-reconcile") [[ -n ${NEVER_HEAL:-} ]] || echo good >"$STATE" ;;
    esac
  }
  nkp() { echo "nkp $*" >>"$T/calls"; }
  sleep() { :; }
  remediate_apps /k/mgmt.conf nkp-mgmt kommander /k/mgmt.conf 2>/dev/null; rc=$?
  check "remediation succeeds" eq "$rc" 0
  check "scaled md-0 to 5 in the MachineDeployment's namespace" grep -q "nkp scale nodepools md-0 --replicas=5 -c nkp-mgmt -n default --kubeconfig=/k/mgmt.conf" "$T/calls"
  check "failed HelmRelease reconciled" grep -q "py k8s hr-reconcile kommander dex --kubeconfig /k/mgmt.conf" "$T/calls"
  check "md-0 looked up on the management cluster" grep -q "py k8s md0 nkp-mgmt --kubeconfig /k/mgmt.conf" "$T/calls"
  echo bad >"$STATE"; rm -f "$T/calls"
  NEVER_HEAL=1 rc=0
  remediate_apps /k/mgmt.conf nkp-mgmt kommander /k/mgmt.conf 2>/dev/null || rc=$?
  check "gives up after two scale-ups" eq "$rc/$(grep -c 'nkp scale' "$T/calls")" "1/2"
)

echo "== destroy order"
(
  setup; UNATTENDED=1; rm -f "$T/calls" "$T/put_body"
  cat >"$WORKDIR/nkp-install.env" <<EOF
CLUSTER_NAME=nkp-mgmt
NUTANIX_ENDPOINT=https://10.0.0.7:9440
NUTANIX_USER=admin
TLS_MODE=insecure
EOF
  mkdir -p "$WORKDIR/nkp-mgmt"; touch "$WORKDIR/nkp-mgmt/nkp-mgmt.conf"
  printf '%s\n' "IP_PLAN_SUBNET=Primary" "IP_PLAN_SUBNET_UUID=sub-1" \
    "IP_PLAN_ORIGINAL_POOLS='[{\"range\":\"10.0.0.50 10.0.0.125\"}]'" "IP_PLAN_ORIGINAL_DHCP='{\"domain_name_server_list\":[\"8.8.8.8\"]}'" \
    "IP_PLAN_DNS=10.0.0.41" "IP_PLAN_BLOCK=10.0.0.96-10.0.0.125" >"$WORKDIR/nkp-ip-plan.env"
  pc_status() { echo 200; }
  ensure_docker_access() { :; }
  kubectl() { echo "kubectl $*" >>"$T/calls"; }
  py() {
    echo "py $*" >>"$T/calls"
    case "$1 $2" in
      "k8s clusters") printf 'default\tnkp-mgmt\nkommander-default-workspace\tnkp-workload1\n' ;;
      "pc subnet-set") printf '%s\n' "$@" >"$T/put_body"; echo 10.0.0.50-10.0.0.125 ;;
    esac
  }
  nkp() { echo "nkp $*" >>"$T/calls"; if [[ "$*" == "delete cluster --help" ]]; then echo "  -c, --cluster-name string"; fi; }
  NKP_DESTROY_CONFIRM=nkp-mgmt NUTANIX_PASSWORD=x phase_destroy 2>"$T/err"; rc=$?
  check "destroy rc 0" eq "$rc" 0
  order=$(grep -E '^nkp (delete cluster -c|create bootstrap|move capi|delete bootstrap)|^py pc subnet-set|wait --for=delete' "$T/calls" \
    | sed -E 's/^nkp delete cluster -c ([^ ]+).*/del:\1/; s/^nkp create bootstrap.*/boot/; s/^nkp move.*/move/; s/^nkp delete bootstrap.*/unboot/; s/^kubectl.*wait --for=delete.*/wait/; s/^py pc subnet-set.*/put/' | tr '\n' ' ')
  check "order: workload delete, wait, bootstrap, move, mgmt delete, bootstrap delete, subnet PUT" eq "$order" "del:nkp-workload1 wait boot move del:nkp-mgmt unboot put "
  check "pool restored" eq "$(sed -n '/--pools-json/{n;p;}' "$T/put_body")" '[{"range":"10.0.0.50 10.0.0.125"}]'
  check "DHCP restored" eq "$(sed -n '/--dhcp/{n;p;}' "$T/put_body")" 'set:{"domain_name_server_list":["8.8.8.8"]}'
  check "files archived" bash -c "ls $WORKDIR/archive-*/nkp-ip-plan.env $WORKDIR/archive-*/nkp-install.env >/dev/null && [[ ! -e $WORKDIR/nkp-ip-plan.env ]]"
)
(
  setup; UNATTENDED=1; rm -f "$T/calls"
  printf 'CLUSTER_NAME=nkp-mgmt\nNUTANIX_ENDPOINT=https://10.0.0.7:9440\nNUTANIX_USER=admin\n' >"$WORKDIR/nkp-install.env"
  mkdir -p "$WORKDIR/nkp-mgmt"; touch "$WORKDIR/nkp-mgmt/nkp-mgmt.conf"
  pc_status() { echo 200; }; ensure_docker_access() { :; }
  kubectl() { :; }
  py() { case "$1 $2" in "k8s clusters") printf 'default\tnkp-mgmt\n' ;; esac; }
  nkp() { echo "nkp $*" >>"$T/calls"; if [[ "$*" == "delete cluster --help" ]]; then echo "      --self-managed   delete a self-managed cluster"; fi; }
  NKP_DESTROY_CONFIRM=nkp-mgmt NUTANIX_PASSWORD=x phase_destroy 2>/dev/null
  check "uses --self-managed when the CLI has it" grep -q "nkp delete cluster -c nkp-mgmt -n default --self-managed" "$T/calls"
  check "no bootstrap then" bash -c "! grep -q 'create bootstrap' $T/calls"
  printf 'CLUSTER_NAME=nkp-mgmt\n' >"$WORKDIR/nkp-install.env"; rm -f "$T/calls"
  check "wrong confirmation refuses" dies 'NKP_DESTROY_CONFIRM=nope phase_destroy'
  check "nothing deleted then" bash -c "! grep -q 'nkp delete' $T/calls 2>/dev/null"
)

(
  setup; UNATTENDED=1; rm -f "$T/calls"
  HOME=$WORKDIR; mkdir -p "$HOME/.kube"; touch "$HOME/.kube/config"
  printf 'CLUSTER_NAME=nkp-mgmt\nNUTANIX_ENDPOINT=https://10.0.0.7:9440\nNUTANIX_USER=admin\n' >"$WORKDIR/nkp-install.env"
  printf '%s\n' "IP_PLAN_SUBNET=Primary" "IP_PLAN_SUBNET_UUID=sub-1" "IP_PLAN_ORIGINAL_POOLS='[]'" >"$WORKDIR/nkp-ip-plan.env"
  mkdir -p "$WORKDIR/nkp-mgmt"; echo stale >"$WORKDIR/nkp-mgmt/nkp-mgmt.conf"
  pc_status() { echo 200; }; ensure_docker_access() { :; }
  kubectl() { echo "kubectl $*" >>"$T/calls"; if [[ "$*" == *"--context kind-konvoy-capi-bootstrapper"* ]]; then echo "kommander   nkp-mgmt"; fi; }
  py() { echo "py $*" >>"$T/calls"; case "$1 $2" in "k8s clusters") return 1 ;; esac; }
  nkp() { echo "nkp $*" >>"$T/calls"; }
  NKP_DESTROY_CONFIRM=nkp-mgmt NUTANIX_PASSWORD=x phase_destroy 2>"$T/err"; rc=$?
  check "bootstrap-held cluster: destroy rc 0" eq "$rc" 0
  order=$(grep -E '^nkp delete|^py pc subnet-set' "$T/calls" | sed -E 's/^nkp delete cluster.*/del/; s/^nkp delete bootstrap.*/unboot/; s/^py pc.*/put/' | tr '\n' ' ')
  check "deleted through the bootstrap, then subnet restored" eq "$order" "del unboot put "
  check "uses the bootstrap kubeconfig and namespace" grep -q "nkp delete cluster -c nkp-mgmt -n kommander --kubeconfig=$HOME/.kube/config" "$T/calls"
  check "stale kubeconfig archived" bash -c "[[ ! -e $WORKDIR/nkp-mgmt/nkp-mgmt.conf ]] && ls $WORKDIR/archive-*/nkp-mgmt.conf >/dev/null"
)

echo "== lab workload questions (offline) and summary"
(
  setup; UNATTENDED=1
  CLUSTER_NAME=nkp-mgmt CONTROLPLANE_IP=10.0.0.95 SERVICE_LB_IP_RANGE=10.0.0.97-10.0.0.110 SIZING=starter SIZING_ARGS=(--x)
  NODE_POOLS=10.0.0.50-10.0.0.94 NODE_CIDR=10.0.0.0/24 SUBNET=Primary PC_HOST=10.0.0.7 ANSWERS_FILE=$WORKDIR/nkp-install.env VM_IMAGE=nkp-rocky-9.8-release-1.36.2
  printf '%s\n' IP_PLAN_SUBNET=Primary IP_PLAN_BLOCK=10.0.0.95-10.0.0.124 WL_CONTROLPLANE_IP=10.0.0.96 WL_LB_RANGE=10.0.0.111-10.0.0.124 >"$WORKDIR/nkp-ip-plan.env"
  ip_responds() { return 1; }
  q_lab_workload 2>/dev/null
  check "mgmt values restored" eq "$CLUSTER_NAME $CONTROLPLANE_IP ${SIZING_ARGS[*]}" "nkp-mgmt 10.0.0.95 --x"
  check "workload values in WL_*" eq "$WL_CLUSTER_NAME $WL_WORKSPACE_NAMESPACE $WL_CONTROLPLANE_IP $WL_LB_RANGE $WL_SIZING" \
    "nkp-workload1 kommander-default-workspace 10.0.0.96 10.0.0.111-10.0.0.124 starter"
  # shellcheck disable=SC1091
  check "nkp-workload.env written" eval '( . "$WORKDIR/nkp-workload.env"; [[ $CLUSTER_NAME == nkp-workload1 && $CONTROLPLANE_IP == 10.0.0.96 && $SUBNET == Primary ]] )'
  check "WL_NEED" eq "$WL_NEED" "7 22 56"
  check "workload name equal to mgmt rejected" dies 'X=nkp-mgmt; ask X n v_lab_workload_name'

  NUTANIX_ENDPOINT=https://10.0.0.7:9440 NUTANIX_USER=admin NUTANIX_CLUSTER=PE1
  save_answers
  mkdir -p "$WORKDIR/nkp-mgmt"; touch "$WORKDIR/nkp-mgmt/nkp-mgmt.conf"
  nkp() { printf 'Username: admin-x\nPassword: secret\nURL: https://10.0.0.97/dkp/kommander/dashboard\n'; }
  kubectl() { echo "nkp-workload1   Joined"; }
  printf '%s\n' IP_PLAN_SUBNET=Primary IP_PLAN_BLOCK=10.0.0.95-10.0.0.124 IP_PLAN_NEW_POOLS=10.0.0.50-10.0.0.94 IP_PLAN_DNS=10.0.0.41 IP_PLAN_DOMAIN=ntnxlab.local >"$WORKDIR/nkp-ip-plan.env"
  write_lab_summary
  f=$WORKDIR/lab-summary.txt
  check "summary mode 600" eq "$(mode "$f")" 600
  check "summary has dashboard password" grep -q "Password: secret" "$f"
  check "summary has DNS" grep -q "10.0.0.41 (autoad) / ntnxlab.local" "$f"
  check "summary has workload kubeconfig" grep -q "$WORKDIR/nkp-workload1/nkp-workload1.conf" "$f"
  check "summary has workload state" grep -q "Joined" "$f"
  cat "$f" | sed 's/^/       | /'
)

echo "== bundle (management cluster)"
mkbundle() { # dir files...
  mkdir -p "$1"; local f; for f in "${@:2}"; do : >"$1/$f"; done
}
(
  setup; UNATTENDED=1; HOME=$WORKDIR PACKAGE="" CLUSTER_NAME=nkp-mgmt
  nkp() { echo "  --bundle strings   --nutanix-registry-username string"; }
  CI=$HOME/nkp-dist/nkp-air-gapped-bundle_v2.19.0_linux_amd64/nkp-v2.19.0/container-images
  mkbundle "$CI" konvoy-image-bundle-v2.19.0.tar kommander-image-bundle-v2.19.0.tar nkp-release-specs-v2.19.0.tar nutanix-product-catalog-v2.19.0-airgapped.tar
  USE_BUNDLE="" BUNDLE_DIR="" USE_CATALOG_BUNDLES=N; q_bundle 2>/dev/null
  CI=$(readlink -f "$CI")
  check "bundle found under ~/nkp-dist" eq "$BUNDLE_DIR" "$CI"
  check "--bundle has konvoy, kommander, release specs (catalogs off)" eq "${BUNDLE_ARGS[*]}" \
    "--bundle=$CI/konvoy-image-bundle-v2.19.0.tar,$CI/kommander-image-bundle-v2.19.0.tar,$CI/nkp-release-specs-v2.19.0.tar"
  check "USE_BUNDLE=Y, 3 files" eq "$USE_BUNDLE $BUNDLE_COUNT" "Y 3"
  : >"$CI/nkp-ai-applications-catalog-image-bundle-2.19.tar"
  USE_CATALOG_BUNDLES=Y; q_bundle 2>/dev/null
  check "every catalog bundle added" eq "$BUNDLE_COUNT ${BUNDLE_ARGS[0]##*,}" "5 $CI/nutanix-product-catalog-v2.19.0-airgapped.tar"
  check "BUNDLE_FILES for the Harbor push" eq "--bundle=$BUNDLE_FILES" "${BUNDLE_ARGS[0]}"
  USE_CATALOG_BUNDLES=N; q_bundle 2>/dev/null
  check "USE_CATALOG_BUNDLES=N: core bundles only" eq "$BUNDLE_COUNT" 3
  USE_CATALOG_BUNDLES=Y USE_BUNDLE=N; q_bundle 2>/dev/null
  check "USE_BUNDLE=N skips" eq "${#BUNDLE_ARGS[@]} $USE_BUNDLE" "0 N"
  OTHER=$WORKDIR/other; mkbundle "$OTHER" konvoy-image-bundle-v2.19.1.tar kommander-image-bundle-v2.19.1.tar
  OTHER=$(readlink -f "$OTHER")
  BUNDLE_DIR_ARG=$OTHER USE_BUNDLE=N; q_bundle 2>/dev/null
  check "--bundle-dir overrides answers" eq "$USE_BUNDLE $BUNDLE_COUNT ${BUNDLE_ARGS[0]}" \
    "Y 2 --bundle=$OTHER/konvoy-image-bundle-v2.19.1.tar,$OTHER/kommander-image-bundle-v2.19.1.tar"
  BUNDLE_DIR_ARG=""
  BAD=$WORKDIR/bad; mkbundle "$BAD" kommander-image-bundle-v2.19.0.tar
  check "missing konvoy tar rejected" eval '! bundle_files "$BAD" 2>/dev/null'
  check "missing konvoy tar dies unattended" dies 'BUNDLE_DIR=$BAD USE_BUNDLE=Y; q_bundle'
  OLD=$WORKDIR/old; mkbundle "$OLD" konvoy-image-bundle-v2.18.1.tar kommander-image-bundle-v2.18.1.tar
  check "2.18 bundle rejected" eval '! bundle_files "$OLD" 2>/dev/null'
  rm -rf "$HOME/nkp-dist"
  USE_BUNDLE="" BUNDLE_DIR=""; q_bundle 2>/dev/null
  check "no bundle: internet, USE_BUNDLE=N" eq "${#BUNDLE_ARGS[@]} $USE_BUNDLE" "0 N"
  check "USE_BUNDLE=Y without a bundle dies unattended" dies 'USE_BUNDLE=Y BUNDLE_DIR=""; q_bundle'
  nkp() { echo "  --nutanix-registry-username string"; }
  USE_BUNDLE="" BUNDLE_DIR=$CI; mkbundle "$CI" konvoy-image-bundle-v2.19.0.tar kommander-image-bundle-v2.19.0.tar; q_bundle 2>/dev/null
  check "CLI without --bundle: not used" eq "${#BUNDLE_ARGS[@]} $USE_BUNDLE" "0 N"
)

echo "== Nutanix registry token with the bundle"
(
  setup; UNATTENDED=1; HOME=$WORKDIR WORKLOAD=0 CLUSTER_NAME=nkp-mgmt USE_DOCKERHUB=N
  mkdir -p "$HOME/.ssh"; echo "ssh-ed25519 AAAA t" >"$HOME/.ssh/id_ed25519.pub"
  nkp() { echo "  --bundle strings   --nutanix-registry-username string"; }
  docker() { cat >/dev/null; return 0; }
  BUNDLE_ARGS=(--bundle=x); unset NUTANIX_REGISTRY_PASSWORD
  q_access 2>/dev/null
  check "token skipped with the bundle" eq "${#NUTANIX_REGISTRY_ARGS[@]}" 0
  check "own Docker Hub default No with the bundle" eq "$USE_DOCKERHUB" N
  NUTANIX_REGISTRY_PASSWORD=tok; q_access 2>/dev/null
  check "exported token used with the bundle" eq "${NUTANIX_REGISTRY_ARGS[*]}" "--nutanix-registry-username=svcregistrynkp --nutanix-registry-password=tok"
  BUNDLE_ARGS=(); unset NUTANIX_REGISTRY_PASSWORD
  check "token required without the bundle" dies 'q_access'
)

(
  setup; set +u; BUNDLE_ARGS=(--bundle=a.tar) REGISTRY_MIRROR_ARGS=(--registry-mirror-url=https://x:5000)
  check "--bundle with --registry-mirror-* dies" dies 'build_command'
  WORKLOAD=0 TRUST_ARGS=() SIZING_ARGS=() NUTANIX_REGISTRY_ARGS=() USE_DOCKERHUB=N USE_PROXY=N NTP_SERVERS="" ONBOARD_PC=Y REGISTRY_MIRROR_ARGS=()
  build_command
  check "management command has --bundle" eval 'printf "%s\n" "${CMD[@]}" | grep -qx -- "--bundle=a.tar"'
)
(
  setup
  printf '%s\n' CLUSTER_NAME=nkp-mgmt USE_BUNDLE=Y CONTROLPLANE_IP=10.0.0.95 NUTANIX_ENDPOINT=https://pc:9440 NUTANIX_USER=admin \
    NUTANIX_CLUSTER=PE1 SUBNET=Primary SERVICE_LB_IP_RANGE=10.0.0.97-10.0.0.110 >"$WORKDIR/nkp-install.env"
  mkdir -p "$WORKDIR/nkp-mgmt"; touch "$WORKDIR/nkp-mgmt/nkp-mgmt.conf"
  printf '%s\n' CLUSTER_NAME=nkp-wl1 WORKSPACE_NAMESPACE=ws USE_MGMT_REGISTRY=Y CONTROLPLANE_IP=10.0.0.96 \
    SERVICE_LB_IP_RANGE=10.0.0.111-10.0.0.124 >"$WORKDIR/nkp-workload.env"
  nkp() { :; }; kubectl() { :; }
  write_lab_summary
  check "lab summary: bundle not pushed yet" grep -q "Harbor               bundle not pushed yet: .* --harbor" "$WORKDIR/lab-summary.txt"
  printf '%s\n' HARBOR_URL=https://10.0.0.98:5000/nkp HARBOR_EXTERNAL=N HARBOR_USER=admin "PUSH_DATE=2026-10-25" >"$WORKDIR/nkp-mgmt/harbor-push.env"
  write_lab_summary
  check "lab summary: Harbor URL and password command" eval 'grep -q "Harbor               https://10.0.0.98:5000/nkp (bundles pushed 2026-10-25)" "$WORKDIR/lab-summary.txt" && grep -q "harbor-admin-password" "$WORKDIR/lab-summary.txt"'
  check "lab summary: workload pulls from it" grep -q "Images               from Harbor https://10.0.0.98:5000/nkp" "$WORKDIR/lab-summary.txt"
  check "lab summary mode 600" eq "$(mode "$WORKDIR/lab-summary.txt")" 600
)

echo
echo "PASS=$(grep -c ok "$T/results") FAIL=$(grep -c FAIL "$T/results")"
! grep -q FAIL "$T/results"
