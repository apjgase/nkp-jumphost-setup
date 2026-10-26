#!/usr/bin/env bash
# NKP 2.19 lab builder for a Linux jump host (Nutanix AHV, non-air-gapped).
#
# Phase 1 installs prerequisites: cgroups v2 check, base tools including tmux, Docker 27.4.0,
#         kubectl 1.36.x, and the nkp CLI from the package you downloaded from the Nutanix Portal.
# Phase 2 relaunches itself inside a tmux session named "nkp" (if you are not already in one),
#         asks for the Prism Central details, reserves IP addresses at the end of the node subnet's
#         IPAM pool and points the subnet's DHCP at the lab DNS server (VM "autoad"), validates
#         everything, runs the NKP preflight checks, then runs `nkp create cluster nutanix --self-managed`.
# --workload then creates a workload (managed) cluster from that management cluster: it reuses the
#         management answers and the reserved addresses as defaults, picks or creates a workspace, and
#         waits until the cluster has joined the workspace and its platform applications are ready.
# --lab   does all of it in one go: every question up front, then the management cluster and the first
#         workload cluster unattended, ending with lab-summary.txt.
# Images: with an NKP package extracted (nkp-v2.19.x/container-images), the management cluster is
#         created with --bundle (its internal registry mirror). The script then deploys Harbor on it as in
#         the NKP guide (CloudNativePG, Rook Ceph raised to 8 x 40 GiB, namespace ncr-system), pushes the
#         bundles into Harbor project "nkp" with `nkp push bundle`, and creates every workload cluster with
#         --registry-mirror-url=https://<ingress>:5000/nkp and a pull-only robot account per cluster.
#         With REGISTRY_MIRROR_URL set (e.g. https://registry.ntnxlab.local/nkp), that registry is used
#         instead and no Harbor is deployed. HARBOR_OVERRIDES_FILE=values.yaml replaces the built-in Harbor
#         values. Prism Central, Kubernetes and Harbor API calls are in nkp_lab.py (keep it next to this script).
#
# Usage:
#   ./nkp-jumphost-setup.sh --check --config nkp-lab.env   (before deploying: nothing is changed)
#   ./nkp-jumphost-setup.sh --lab [--config nkp-lab.env]
#   ./nkp-jumphost-setup.sh [--package nkp-bundle_v2.19.x_linux_amd64.tar.gz] [options]
#   ./nkp-jumphost-setup.sh --harbor
#   ./nkp-jumphost-setup.sh --workload
#   ./nkp-jumphost-setup.sh --destroy
#
# Options:
#   --package PATH    NKP package from the Nutanix Portal (nkp_*, nkp-bundle_* or
#                     nkp-air-gapped-bundle_*.tar.gz). Auto-detected in the current
#                     directory, $HOME and $HOME/Downloads when omitted.
#   --bundle-dir DIR  container-images directory of an extracted NKP package. Default: the newest
#                     nkp-v2.19.x/container-images under $HOME/nkp-dist (where --package extracts) or $HOME.
#   --workdir DIR     Where answers, logs and the kubeconfig are kept (default: $HOME/nkp).
#   --prereqs-only    Run phase 1 only.
#   --skip-prereqs    Run phase 2 only.
#   --print-only      Do everything except the final cluster creation; print the command.
#   --insecure        Do not verify Prism Central's TLS certificate, without asking.
#   --check           Read-only readiness test of the real lab before (or between) deployments: jump host
#                     tools, nkp_lab.py self-test, bundle, Prism Central login and inventory, IP plan dry run,
#                     lab DNS, capacity, REGISTRY_MIRROR_URL, and the management cluster if it exists.
#                     Changes nothing; exit 1 if any check fails. Report: <workdir>/lab-check.txt.
#   --status          Show what is still not ready on a cluster this script already created.
#   --workload        Create a workload (managed) cluster on the management cluster this script
#                     created: it attaches to a workspace you choose. Run after the management cluster is up.
#   --harbor          Deploy Harbor on the management cluster (if missing) and push the bundle into it;
#                     skipped when that cluster already has these bundles. Runs after the management cluster.
#   --lab             Prerequisites, management cluster and first workload cluster in one run.
#   --config FILE     Answers file (see --init-config) used as defaults; with --unattended, as the answers.
#   --init-config     Write a commented answers template to ./nkp-lab.env and exit.
#   --unattended      Never prompt: take every default, stop if one is missing or invalid.
#                     Passwords must then be exported (see below).
#   --no-ip-plan      Do not reserve addresses from the IPAM pool or change the subnet's DHCP options.
#   --destroy         Delete the workload cluster(s), then the management cluster, and restore the
#                     subnet's IPAM pool and DHCP options. With --unattended, export
#                     NKP_DESTROY_CONFIRM=<management cluster name> instead of typing it.
#   -h, --help        Show this help.
#
# Passwords are not saved in the answers file; to skip their prompts, export NUTANIX_PASSWORD,
# DOCKERHUB_PASSWORD, NUTANIX_REGISTRY_PASSWORD (optional with the bundle) and REGISTRY_MIRROR_PASSWORD before running. The preflight dry-run manifest (cluster-dryrun.yaml,
# mode 600) does contain the credentials, because nkp renders them into Kubernetes secrets. If the jump host reaches the internet through a proxy,
# configure apt/dnf for it and export HTTP_PROXY/HTTPS_PROXY/NO_PROXY before running.

# shellcheck disable=SC2034  # arrays handed to pick() by name look unused to shellcheck
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
PY_HELPER="$(dirname "$SCRIPT_PATH")/nkp_lab.py"
ORIG_ARGS=("$@")
PC_TLS=insecure

NKP_MINOR="2.19"
DOCKER_VERSION="27.4.0"
KUBECTL_MINOR="1.36"
KUBECTL_FALLBACK="v1.36.2"
K8S_VERSION_HINT="1.36"
DOCKERHUB_URL="https://registry-1.docker.io"
NUTANIX_REGISTRY_DEFAULT_USER="svcregistrynkp"
MIN_WORKERS=4  # two 4 vCPU workers (the documented Starter minimum) leave Kommander apps Pending on CPU
NCR_PORT=5000
CEPH_OSD_DEFAULT=4   # Rook Ceph volumes (40 GiB each) of a default management cluster, about 120 GiB usable
CEPH_OSD_COUNT=8     # raised for Harbor, which needs about 100 GiB (NKP 2.19 "Increasing Rook Ceph Storage Capacity")
HARBOR_DISK_GIB=$(((CEPH_OSD_COUNT - CEPH_OSD_DEFAULT) * 40))

PACKAGE=""
WORKDIR="${HOME}/nkp"
DO_PREREQS=1
DO_SETUP=1
PRINT_ONLY=0
FORCE_INSECURE=0
STATUS_ONLY=0
CHECK=0
WORKLOAD=0
LAB=0
UNATTENDED=0
CONFIG_FILE=""
INIT_CONFIG=0
NO_IP_PLAN=0
DESTROY=0
LAB_DNS_VM=autoad
LAB_DOMAIN=ntnxlab.local
WORKSPACE_NAMESPACE=""
RESERVED_RANGES=""
MGMT_CLUSTER_NAME=""
MGMT_KCFG=""
MGMT_K=()
MGMT_USE_BUNDLE=N
BUNDLE_DIR_ARG=""
BUNDLE_ARGS=()
BUNDLE_COUNT=0
BUNDLE_FILES=""
REGISTRY_MIRROR_ARGS=()
NCR_URL=""
NCR_AUTH=""
NCR_CACERT=""
HARBOR_ONLY=0
HARBOR_PROJECT=nkp
HARBOR_OVERRIDES_FILE=${HARBOR_OVERRIDES_FILE:-}  # Harbor AppDeployment values (YAML) instead of the built-in Rook Ceph S3 ones
HARBOR_URL="" HARBOR_CACERT="" HARBOR_USER="" HARBOR_PASSWORD="" HARBOR_EXTERNAL=N

if [[ -t 1 ]]; then
  C_B=$'\e[1m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_C=$'\e[36m' C_0=$'\e[0m'
else
  C_B="" C_G="" C_Y="" C_R="" C_C="" C_0=""
fi

step() { printf '\n%s==> %s%s\n' "$C_B$C_C" "$*" "$C_0" >&2; }
info() { printf '    %s\n' "$*" >&2; }
ok()   { printf '    %s✔%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'rc=$?; err "Failed (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}"; exit "${rc}"' ERR
trap 'stty echo 2>/dev/null || true; echo; exit 130' INT

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$SCRIPT_PATH"; }

parse_args() {
  while (($#)); do
    case $1 in
      --package)      PACKAGE=${2:?--package needs a path}; shift ;;
      --workdir)      WORKDIR=${2:?--workdir needs a path}; shift ;;
      --bundle-dir)   BUNDLE_DIR_ARG=${2:?--bundle-dir needs a directory}; shift ;;
      --prereqs-only) DO_SETUP=0 ;;
      --skip-prereqs) DO_PREREQS=0 ;;
      --print-only)   PRINT_ONLY=1 ;;
      --insecure)     FORCE_INSECURE=1 ;;
      --status)       STATUS_ONLY=1 ;;
      --check)        CHECK=1 ;;
      --workload)     WORKLOAD=1 TMUX_SESSION=nkp-workload ;;
      --harbor)       HARBOR_ONLY=1 TMUX_SESSION=nkp-harbor ;;
      --lab)          LAB=1 ;;
      --config)       CONFIG_FILE=${2:?--config needs a file}; shift ;;
      --init-config)  INIT_CONFIG=1 ;;
      --unattended)   UNATTENDED=1 ;;
      --no-ip-plan)   NO_IP_PLAN=1 ;;
      --destroy)      DESTROY=1 ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  [[ -z $PACKAGE ]] || PACKAGE=$(readlink -f "$PACKAGE")
  if [[ -n $BUNDLE_DIR_ARG ]]; then
    [[ -d $BUNDLE_DIR_ARG ]] || die "--bundle-dir: ${BUNDLE_DIR_ARG} is not a directory."
    BUNDLE_DIR_ARG=$(readlink -f "$BUNDLE_DIR_ARG")
  fi
  if [[ -n $HARBOR_OVERRIDES_FILE ]]; then
    [[ -r $HARBOR_OVERRIDES_FILE ]] || die "Cannot read HARBOR_OVERRIDES_FILE ${HARBOR_OVERRIDES_FILE}."
    HARBOR_OVERRIDES_FILE=$(readlink -f "$HARBOR_OVERRIDES_FILE")
  fi
  if [[ -n $CONFIG_FILE ]]; then
    [[ -r $CONFIG_FILE ]] || die "Cannot read the config file ${CONFIG_FILE}."
    CONFIG_FILE=$(readlink -f "$CONFIG_FILE")
  fi
}

load_config() { # sources --config; it may also set LAB_DNS_VM, LAB_DOMAIN and WL_* keys
  [[ -n $CONFIG_FILE ]] || return 1
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  info "Defaults from ${CONFIG_FILE}"
}

# Workload values that differ from the management cluster's: KEY or KEY:WL_NAME (default WL_KEY).
WL_MAP=(CLUSTER_NAME WORKSPACE_NAMESPACE CONTROLPLANE_IP SERVICE_LB_IP_RANGE:WL_LB_RANGE
        SIZING CP_REPLICAS CP_VCPUS CP_MEMORY WK_REPLICAS WK_VCPUS WK_MEMORY)

swap_wl() { # exchange the current values with the WL_* ones
  local p k w t
  for p in "${WL_MAP[@]}"; do
    k=${p%%:*} w=WL_${p}
    if [[ $p == *:* ]]; then w=${p#*:}; fi
    t=${!k:-}
    printf -v "$k" '%s' "${!w:-}"
    printf -v "$w" '%s' "$t"
  done
}

apply_wl() { # non-empty WL_* values override the current ones
  local p k w
  for p in "${WL_MAP[@]}"; do
    k=${p%%:*} w=WL_${p}
    if [[ $p == *:* ]]; then w=${p#*:}; fi
    if [[ -n ${!w:-} ]]; then printf -v "$k" '%s' "${!w}"; fi
  done
}

init_config() {
  local f="$PWD/nkp-lab.env"
  if [[ -e $f ]] && ! ask_yn "${f} exists. Overwrite it?" N; then exit 0; fi
  cat >"$f" <<'EOF'
# NKP lab answers for nkp-jumphost-setup.sh --lab --config nkp-lab.env [--unattended]
# Blank values fall back to the script's defaults or are discovered from Prism Central.
# Passwords are never read from this file: export NUTANIX_PASSWORD and NUTANIX_REGISTRY_PASSWORD
# (the registry token is optional when the bundle seeds the internal registry), and REGISTRY_MIRROR_PASSWORD.

# Management cluster
CLUSTER_NAME=nkp-mgmt
NUTANIX_ENDPOINT=                 # Prism Central, e.g. https://10.42.x.39:9440
NUTANIX_USER=admin
TLS_MODE=insecure                 # insecure | fetched | cafile (with PC_CA_FILE)
NUTANIX_CLUSTER=                  # Prism Element name; blank = the only one
SUBNET=                           # blank = primary, or primary-<Prism Element>
VM_IMAGE=                         # blank = the only image whose name contains 1.36
STORAGE_CONTAINER_NAME=default
CONTROLPLANE_IP=                  # blank = from the IP plan
SERVICE_LB_IP_RANGE=              # blank = from the IP plan
POD_CIDR=192.168.0.0/16
SERVICE_CIDR=10.96.0.0/12
SIZING=pro                        # pro | starter | custom (then CP_* and WK_* below); starter is too small for a management cluster
CP_REPLICAS=
CP_VCPUS=
CP_MEMORY=
WK_REPLICAS=
WK_VCPUS=
WK_MEMORY=
SSH_USERNAME=nkpadmin
SSH_PUBLIC_KEY=                   # blank = ~/.ssh/id_ed25519.pub, generated if missing
NUTANIX_REGISTRY_USERNAME=svcregistrynkp
USE_DOCKERHUB=N
DOCKERHUB_USERNAME=
USE_PROXY=N
PROXY_HTTP=
PROXY_HTTPS=
PROXY_NO=
NTP_SERVERS=                      # blank = Prism Central's NTP servers
ONBOARD_PC=Y

# Images: seed the management cluster's Harbor from the extracted NKP package
USE_BUNDLE=                       # Y | N; blank = Y when an extracted nkp-v2.19.x/container-images is found
BUNDLE_DIR=                       # blank = newest nkp-v2.19.*/container-images under ~/nkp-dist or ~
USE_CATALOG_BUNDLES=Y             # also the *catalog*.tar bundles (AI applications, Nutanix product catalog)

# Workload clusters pull from the management cluster's Harbor. Blank URL = its internal address
# (:5000) with a robot account. With a URL, the bundle is pushed there once; export REGISTRY_MIRROR_PASSWORD.
REGISTRY_MIRROR_URL=              # e.g. https://registry.ntnxlab.local/nkp
REGISTRY_MIRROR_USERNAME=         # pushes as this user (blank = admin); workload clusters get a robot account
REGISTRY_MIRROR_CACERT=           # CA certificate file of that endpoint; blank = the system trust store

# Lab network: DNS server VM and domain handed out by the subnet's DHCP
LAB_DNS_VM=autoad
LAB_DOMAIN=ntnxlab.local

# Workload cluster: WL_* keys override the management values above for the workload cluster
WL_CLUSTER_NAME=nkp-workload1
WL_WORKSPACE_NAMESPACE=kommander-default-workspace
WL_SIZING=starter
WL_CONTROLPLANE_IP=               # blank = from the IP plan
WL_LB_RANGE=                      # blank = from the IP plan
EOF
  chmod 600 "$f"
  ok "Wrote ${f}. Edit it, then run: ${SCRIPT_PATH} --lab --config ${f}"
}

# ---------------------------------------------------------------------------
# Prompt helpers. Every prompt offers the variable's current value as default.
# ---------------------------------------------------------------------------

ask() { # VAR "Prompt" [validator]; validator "optional" allows an empty answer
  local __var=$1 __prompt=$2 __validator=${3-} __def __ans
  __def=${!__var:-}
  if ((UNATTENDED)); then
    if [[ -z $__def ]]; then
      if [[ $__validator == optional ]]; then printf -v "$__var" '%s' ""; info "${__prompt}: (blank)"; return; fi
      die "--unattended: no value for ${__var} (${__prompt}). Set it in the config file."
    fi
    if [[ -n $__validator && $__validator != optional ]] && ! "$__validator" "$__def"; then
      die "--unattended: invalid ${__var}=${__def} (${__prompt})."
    fi
    info "${__prompt}: ${__def}"
    return
  fi
  while :; do
    if [[ -n $__def ]]; then
      read -r -p "    ${__prompt} [${__def}]: " __ans </dev/tty
      __ans=${__ans:-$__def}
    else
      read -r -p "    ${__prompt}: " __ans </dev/tty
    fi
    if [[ -z $__ans ]]; then
      if [[ $__validator == optional ]]; then printf -v "$__var" '%s' ""; return; fi
      echo "      A value is required." >&2; continue
    fi
    if [[ -n $__validator && $__validator != optional ]] && ! "$__validator" "$__ans"; then continue; fi
    printf -v "$__var" '%s' "$__ans"
    return
  done
}

ask_secret() { # VAR "Prompt"; skipped when VAR is already set in the environment
  local __var=$1 __prompt=$2 __ans
  [[ -n ${!__var:-} ]] && { info "${__prompt}: using value from \$${__var}"; return; }
  ((UNATTENDED)) && die "--unattended: export ${__var} (${__prompt}) before running."
  while :; do
    read -r -s -p "    ${__prompt}: " __ans </dev/tty; echo >&2
    [[ -n $__ans ]] && break
    echo "      A value is required." >&2
  done
  printf -v "$__var" '%s' "$__ans"
}

ask_yn() { # "Prompt" Y|N -> exit status 0 for yes
  local __prompt=$1 __def=${2:-Y} __ans __hint="[Y/n]"
  [[ $__def == N ]] && __hint="[y/N]"
  if ((UNATTENDED)); then
    info "${__prompt} ${__hint}: ${__def}"
    if [[ $__def == N ]]; then return 1; fi
    return 0
  fi
  while :; do
    read -r -p "    ${__prompt} ${__hint}: " __ans </dev/tty
    __ans=${__ans:-$__def}
    case ${__ans,,} in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

pick() { # VAR "Prompt" values_array [labels_array]
  local __var=$1 __prompt=$2
  local -n __vals=$3
  local -n __labels=${4:-$3}
  local __cur=${!__var:-} __def="" __ans __i
  if ((${#__vals[@]} == 0)); then ask "$__var" "$__prompt"; return; fi
  if ((${#__vals[@]} == 1)) && [[ -z $__cur || $__cur == "${__vals[0]}" ]]; then
    printf -v "$__var" '%s' "${__vals[0]}"
    ok "${__prompt}: ${__labels[0]} (only choice)"
    return
  fi
  if ((UNATTENDED)); then
    for __i in "${!__vals[@]}"; do
      if [[ ${__vals[$__i]} == "$__cur" ]]; then info "${__prompt}: ${__labels[$__i]}"; return; fi
    done
    for __i in "${!__vals[@]}"; do
      # Prism Central names are case-sensitive for NKP; adopt the exact spelling.
      if [[ ${__vals[$__i],,} == "${__cur,,}" ]]; then
        printf -v "$__var" '%s' "${__vals[$__i]}"; warn "${__prompt}: using '${__vals[$__i]}' (exact case)"; return
      fi
    done
    die "--unattended: ${__var}='${__cur}' is not one of: ${__vals[*]} (${__prompt})."
  fi
  echo "    ${__prompt}:" >&2
  for __i in "${!__vals[@]}"; do
    printf '      %2d) %s\n' $((__i + 1)) "${__labels[$__i]}" >&2
    if [[ ${__vals[$__i]} == "$__cur" ]]; then __def=$((__i + 1)); fi
  done
  printf '       m) enter a value manually\n' >&2
  while :; do
    read -r -p "    Choice${__def:+ [$__def]}: " __ans </dev/tty
    __ans=${__ans:-$__def}
    if [[ $__ans == m ]]; then ask "$__var" "$__prompt"; return; fi
    if [[ $__ans =~ ^[0-9]+$ ]] && ((10#$__ans >= 1 && 10#$__ans <= ${#__vals[@]})); then
      printf -v "$__var" '%s' "${__vals[$((10#$__ans - 1))]}"
      return
    fi
    echo "      Enter a number from the list, or m." >&2
  done
}

# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

py() { # nkp_lab.py with the Prism Central login in its environment (never on the command line)
  NKP_PC_ENDPOINT="${NUTANIX_ENDPOINT:-}" NKP_PC_USER="${NUTANIX_USER:-}" NKP_PC_PASSWORD="${NUTANIX_PASSWORD:-}" \
    NKP_PC_TLS="${PC_TLS:-insecure}" NKP_CACHE="${WORKDIR}/cache" python3 "$PY_HELPER" "$@"
}

py_vars() { # nkp_lab.py command printing KEY=value lines -> sets those variables; returns its exit status
  local __out __k __v __rc=0
  __out=$(py "$@") || __rc=$?
  while IFS='=' read -r __k __v; do
    if [[ $__k =~ ^[A-Z_][A-Z0-9_]*$ ]]; then printf -v "$__k" '%s' "$__v"; fi
  done <<<"$__out"
  return "$__rc"
}

ipcalc() { py ip "$@"; } # op args... -> exit status; range_first prints the first address

v_cluster_name() {
  if [[ $1 =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && ((${#1} <= 58)); then return 0; fi
  echo "      Use lowercase letters, digits, '.' and '-', starting and ending with a letter or digit, max 58 characters." >&2
  return 1
}
v_ip()    { ipcalc ip "$1"    || { echo "      Not a valid IP address." >&2; return 1; }; }
v_cidr()  { ipcalc cidr "$1"  || { echo "      Use CIDR notation, for example 192.168.0.0/16." >&2; return 1; }; }
v_range() { ipcalc range "$1" || { echo "      Use first-last, for example 10.0.0.150-10.0.0.160." >&2; return 1; }; }
v_int()   { [[ $1 =~ ^[1-9][0-9]*$ ]] || { echo "      Enter a positive whole number." >&2; return 1; }; }
v_workers() {
  if [[ $1 =~ ^[1-9][0-9]*$ ]] && (($1 >= MIN_WORKERS)); then return 0; fi
  echo "      Use at least ${MIN_WORKERS} workers." >&2; return 1
}
v_dns_label() {
  if [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && ((${#1} <= 63)); then return 0; fi
  echo "      Use lowercase letters, digits and '-', starting and ending with a letter or digit, max 63 characters." >&2
  return 1
}
v_cp_replicas() { [[ $1 =~ ^[135]$ ]] || { echo "      Use 1, 3 or 5 (3 for production)." >&2; return 1; }; }
v_file()  { [[ -r $1 ]] || { echo "      File not found or not readable: $1" >&2; return 1; }; }
v_endpoint() {
  [[ $1 =~ ^(https?://)?[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] && return 0
  echo "      Use host, host:port or https://host:port." >&2
  return 1
}

ip_responds() { ping -c1 -W1 "$1" >/dev/null 2>&1; }

retry_guard() { # COUNTER_VAR: call at the top of a question loop; --unattended cannot re-ask, so it stops instead
  local -n __n=$1
  __n=$((__n + 1))
  if ((UNATTENDED && __n > 1)); then die "--unattended: the value above was rejected. Fix it in the config file."; fi
}

default_match() { # VAR values_array regex: if VAR is empty, set it to the first value matching regex (case-insensitive)
  local -n __dm_vals=$2
  local __v
  [[ -z ${!1:-} ]] || return 0
  for __v in "${__dm_vals[@]}"; do
    if [[ ${__v,,} =~ $3 ]]; then printf -v "$1" '%s' "$__v"; return 0; fi
  done
}

# ---------------------------------------------------------------------------
# Phase 1: prerequisites
# ---------------------------------------------------------------------------

setup_sudo() {
  if ((EUID == 0)); then SUDO=(); return; fi
  command -v sudo >/dev/null || die "sudo is required when not running as root."
  SUDO=(sudo)
  sudo -v || die "sudo authentication failed."
}

detect_os() {
  [[ $(uname -s) == Linux ]]  || die "This script supports Linux jump hosts only."
  [[ $(uname -m) == x86_64 ]] || die "NKP supports x86_64 (amd64) only; this host is $(uname -m)."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-unknown}
  OS_CODENAME=${VERSION_CODENAME:-}
  case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*|*" debian "*)                            OS_FAMILY=debian ;;
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) OS_FAMILY=rhel ;;
    *) die "Unsupported distribution '${PRETTY_NAME:-$OS_ID}'. Use Ubuntu/Debian or RHEL/Rocky/Alma." ;;
  esac
  ok "OS: ${PRETTY_NAME:-$OS_ID} (${OS_FAMILY} family)"
}

check_resources() {
  local cpus mem_avail_kb free_kb
  cpus=$(nproc)
  mem_avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  free_kb=$(df -Pk /var/lib | awk 'NR==2 {print $4}')
  if ((cpus >= 4)); then ok "CPUs: ${cpus}"
  else warn "Only ${cpus} CPUs. The bootstrap cluster needs at least 4 free CPUs."; fi
  if ((mem_avail_kb >= 4 * 1024 * 1024)); then ok "Available memory: $((mem_avail_kb / 1024 / 1024)) GiB"
  else warn "Only $((mem_avail_kb / 1024)) MiB memory available. The bootstrap cluster needs at least 4 GiB."; fi
  if ((free_kb >= 30 * 1024 * 1024)); then ok "Free space under /var/lib: $((free_kb / 1024 / 1024)) GiB"
  else warn "Only $((free_kb / 1024 / 1024)) GiB free under /var/lib (Docker images). 30 GiB or more is recommended."; fi
}

ensure_cgroup_v2() {
  if [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]; then ok "cgroups v2 is enabled"; return; fi
  warn "cgroups v2 is not enabled. NKP requires it on Linux hosts."
  ask_yn "Enable cgroups v2 now? (a reboot is required afterwards)" Y || die "cgroups v2 is required."
  if [[ $OS_FAMILY == rhel ]]; then
    "${SUDO[@]}" grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"
  else
    "${SUDO[@]}" sed -i -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub
    "${SUDO[@]}" update-grub
  fi
  die "cgroups v2 configured. Reboot the jump host, then rerun this script."
}

install_base_packages() {
  local -A deb=( [curl]=curl [jq]=jq [openssl]=openssl [python3]=python3 [tar]=tar [gzip]=gzip
                 [ping]=iputils-ping [ssh-keygen]=openssh-client [sha256sum]=coreutils [gpg]=gnupg [tmux]=tmux )
  local -A rpm=( [curl]=curl [jq]=jq [openssl]=openssl [python3]=python3 [tar]=tar [gzip]=gzip
                 [ping]=iputils [ssh-keygen]=openssh-clients [sha256sum]=coreutils [tmux]=tmux )
  local cmd pkgs=()
  if [[ $OS_FAMILY == debian ]]; then
    for cmd in "${!deb[@]}"; do command -v "$cmd" >/dev/null || pkgs+=("${deb[$cmd]}"); done
    pkgs+=(ca-certificates)
    "${SUDO[@]}" apt-get update -q
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}"
  else
    for cmd in "${!rpm[@]}"; do command -v "$cmd" >/dev/null || pkgs+=("${rpm[$cmd]}"); done
    if ((${#pkgs[@]})); then "${SUDO[@]}" dnf -y -q install "${pkgs[@]}"; fi
  fi
  ok "Base tools present (curl, jq, openssl, python3, ssh-keygen, tmux)"
}

docker_installed_version() {
  command -v docker >/dev/null || return 0
  docker --version 2>/dev/null | sed -nE 's/^Docker version ([0-9.]+).*/\1/p'
}

rpm_repo_version() { # package -> epoch:version-release matching DOCKER_VERSION, e.g. 1:27.4.0-1.el9
  dnf -q list --showduplicates "$1" 2>/dev/null \
    | awk -v v="$DOCKER_VERSION" '$2 ~ ("(^|:)" v "-") {print $2}' | tail -1
}

install_docker() {
  local cur pkgver clipkgver
  cur=$(docker_installed_version)
  if [[ $cur == "$DOCKER_VERSION" ]]; then
    ok "Docker ${cur} already installed"
  else
    if [[ -n $cur ]]; then
      warn "Docker ${cur} is installed; the NKP ${NKP_MINOR} docs require ${DOCKER_VERSION}."
      if ! ask_yn "Replace it with Docker ${DOCKER_VERSION}? (images and containers are kept)" Y; then
        warn "Keeping Docker ${cur}."
        configure_docker
        return
      fi
    fi
    info "Installing Docker ${DOCKER_VERSION}..."
    if [[ $OS_FAMILY == debian ]]; then
      [[ $OS_ID == ubuntu || $OS_ID == debian ]] || die "Docker's apt repo supports Ubuntu and Debian only (found ${OS_ID})."
      "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get remove -y -q \
        docker.io docker-doc docker-compose podman-docker containerd runc >/dev/null 2>&1 || true
      "${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | "${SUDO[@]}" tee /etc/apt/keyrings/docker.asc >/dev/null
      "${SUDO[@]}" chmod 0644 /etc/apt/keyrings/docker.asc
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
        | "${SUDO[@]}" tee /etc/apt/sources.list.d/docker.list >/dev/null
      "${SUDO[@]}" apt-get update -q
      pkgver=$(apt-cache madison docker-ce | awk -v v="$DOCKER_VERSION" '$3 ~ ("^5:" v "-") {print $3; exit}')
      [[ -n $pkgver ]] || die "Docker ${DOCKER_VERSION} is not available for ${OS_ID} ${OS_CODENAME}."
      "${SUDO[@]}" apt-mark unhold docker-ce docker-ce-cli >/dev/null 2>&1 || true
      "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --allow-downgrades \
        "docker-ce=${pkgver}" "docker-ce-cli=${pkgver}" containerd.io docker-buildx-plugin
      "${SUDO[@]}" apt-mark hold docker-ce docker-ce-cli >/dev/null
    else
      local repo_os=centos
      if [[ $OS_ID == rhel ]]; then repo_os=rhel; fi
      "${SUDO[@]}" dnf -y -q install dnf-plugins-core
      "${SUDO[@]}" dnf config-manager --add-repo "https://download.docker.com/linux/${repo_os}/docker-ce.repo"
      # docker-ce and docker-ce-cli use different RPM epochs, so resolve each one separately.
      pkgver=$(rpm_repo_version docker-ce)
      clipkgver=$(rpm_repo_version docker-ce-cli)
      [[ -n $pkgver && -n $clipkgver ]] || die "Docker ${DOCKER_VERSION} is not available in the Docker ${repo_os} repo."
      "${SUDO[@]}" dnf -y -q remove podman-docker docker docker-client docker-common docker-latest docker-engine >/dev/null 2>&1 || true
      if [[ -n $cur ]]; then
        "${SUDO[@]}" dnf versionlock delete docker-ce docker-ce-cli >/dev/null 2>&1 || true
        "${SUDO[@]}" dnf -y -q remove docker-ce docker-ce-cli
      fi
      "${SUDO[@]}" dnf -y -q install --allowerasing "docker-ce-${pkgver}" "docker-ce-cli-${clipkgver}" containerd.io docker-buildx-plugin
      if "${SUDO[@]}" dnf -y -q install python3-dnf-plugin-versionlock >/dev/null 2>&1; then
        "${SUDO[@]}" dnf versionlock add docker-ce docker-ce-cli >/dev/null 2>&1 || true
      fi
    fi
    ok "Docker $(docker_installed_version) installed and pinned"
  fi
  configure_docker
}

configure_docker() {
  local http=${HTTP_PROXY:-${http_proxy:-}} https=${HTTPS_PROXY:-${https_proxy:-}} no=${NO_PROXY:-${no_proxy:-}}
  if [[ -n $http || -n $https ]]; then
    "${SUDO[@]}" mkdir -p /etc/systemd/system/docker.service.d
    printf '[Service]\nEnvironment="HTTP_PROXY=%s"\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="NO_PROXY=%s"\n' \
      "$http" "${https:-$http}" "$no" | "${SUDO[@]}" tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null
    "${SUDO[@]}" systemctl daemon-reload
    ok "Docker configured to use the proxy from your environment"
  fi
  # The kind-based bootstrap cluster exhausts the distro default inotify limits.
  printf 'fs.inotify.max_user_watches = 524288\nfs.inotify.max_user_instances = 512\n' \
    | "${SUDO[@]}" tee /etc/sysctl.d/99-nkp-bootstrap.conf >/dev/null
  "${SUDO[@]}" sysctl -q --system >/dev/null
  "${SUDO[@]}" systemctl enable docker >/dev/null 2>&1
  "${SUDO[@]}" systemctl restart docker
  "${SUDO[@]}" docker info >/dev/null || die "Docker daemon is not responding."
  ok "Docker daemon running"
  if ((EUID != 0)) && ! id -nG "$USER" | grep -qw docker; then
    "${SUDO[@]}" usermod -aG docker "$USER"
    ok "Added ${USER} to the docker group"
  fi
}

install_kubectl() {
  local cur ver tmp
  cur=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' || true)
  if [[ $cur == v${KUBECTL_MINOR}.* ]]; then ok "kubectl ${cur} already installed"; return; fi
  [[ -n $cur ]] && warn "kubectl ${cur} found; NKP ${NKP_MINOR} needs ${KUBECTL_MINOR}.x. Replacing /usr/local/bin/kubectl."
  ver=$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt" 2>/dev/null || echo "$KUBECTL_FALLBACK")
  tmp=$(mktemp -d)
  curl -fsSLo "${tmp}/kubectl" "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl"
  curl -fsSLo "${tmp}/kubectl.sha256" "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl.sha256"
  echo "$(cat "${tmp}/kubectl.sha256")  ${tmp}/kubectl" | sha256sum --check --quiet || die "kubectl checksum mismatch."
  "${SUDO[@]}" install -m 0755 "${tmp}/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
  ok "kubectl ${ver} installed"
}

find_package() {
  local dir candidates=()
  for dir in "$PWD" "$HOME" "$HOME/Downloads"; do
    [[ -d $dir ]] || continue
    while IFS= read -r -d '' f; do candidates+=("$f"); done \
      < <(find "$dir" -maxdepth 1 -type f -name 'nkp[_-]*linux_amd64.tar.gz' -print0 2>/dev/null)
  done
  mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | awk 'NF && !seen[$0]++')
  case ${#candidates[@]} in
    0) PACKAGE="" ;;
    1) PACKAGE=${candidates[0]} ;;
    *) pick PACKAGE "Several NKP packages found; which one" candidates ;;
  esac
}

nkp_release() { # the "nkp:" line of 'nkp version' (the other lines are component versions such as catalog: v0.11.1)
  nkp version 2>/dev/null | awk '$1 == "nkp:" {print $2; exit}' || true
}

install_nkp() {
  local dest bin ver
  [[ -n $PACKAGE ]] || find_package
  if [[ -z $PACKAGE ]]; then
    if command -v nkp >/dev/null; then
      warn "No NKP package found; using the nkp already on PATH."
    else
      die "No NKP package found. Download the NKP package from the Nutanix Portal and pass --package PATH."
    fi
  else
    [[ -r $PACKAGE ]] || die "Cannot read ${PACKAGE}. Check the exact file name with: ls $(dirname "$PACKAGE")/nkp*.tar.gz"
    dest="${HOME}/nkp-dist/$(basename "$PACKAGE" .tar.gz)"
    info "Extracting $(basename "$PACKAGE") to ${dest} ..."
    mkdir -p "$dest"
    tar -xzf "$PACKAGE" -C "$dest"
    bin=$(find "$dest" -maxdepth 4 -type f -name nkp | head -1)
    [[ -n $bin ]] || die "No nkp binary found inside ${PACKAGE}."
    "${SUDO[@]}" install -m 0755 "$bin" /usr/local/bin/nkp
  fi
  ver=$(nkp_release)
  if [[ $ver == v"${NKP_MINOR}".* ]]; then ok "nkp CLI: ${ver}"; else warn "nkp version reports ${ver:-no nkp: line}. Expected v${NKP_MINOR}.x."; fi
}

phase_prereqs() {
  step "Phase 1: jump host prerequisites"
  setup_sudo
  detect_os
  check_resources
  ensure_cgroup_v2
  install_base_packages
  install_docker
  install_kubectl
  install_nkp
}

# ---------------------------------------------------------------------------
# Phase 2: interactive setup
# ---------------------------------------------------------------------------

ensure_docker_access() {
  if docker info >/dev/null 2>&1; then return; fi
  ((EUID == 0)) && die "Docker daemon is not reachable."
  if id -nG "$USER" | grep -qw docker && command -v sg >/dev/null && [[ -z ${NKP_SG_REEXEC:-} ]]; then
    info "Re-running under the docker group (new group membership is not active in this session yet)..."
    exec sg docker -c "NKP_SG_REEXEC=1 $(printf '%q ' bash "$SCRIPT_PATH" --skip-prereqs "${ORIG_ARGS[@]}")"
  fi
  die "Cannot talk to Docker as ${USER}. Log out and back in (docker group), then rerun with --skip-prereqs."
}

TMUX_SESSION=nkp

ensure_tmux_session() {
  if [[ -n ${NKP_LAB_CHILD:-} ]]; then return 0; fi
  if [[ -n ${TMUX:-} || -n ${STY:-} ]]; then ok "Running inside tmux/screen"; return; fi
  warn "Not inside tmux or screen. Cluster creation takes 30-60 minutes and stops if this SSH session drops."
  if ! command -v tmux >/dev/null; then
    ask_yn "tmux is not installed. Continue without it?" N \
      || die "Install tmux (rerun without --skip-prereqs, or: dnf/apt install tmux) and try again."
    return
  fi
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    info "A tmux session named '${TMUX_SESSION}' already exists. Attach to it with: tmux attach -t ${TMUX_SESSION}"
    ask_yn "Continue here without tmux instead?" N || exit 0
    return
  fi
  if ask_yn "Relaunch the setup inside a tmux session named '${TMUX_SESSION}'? (recommended)" Y; then
    info "If your connection drops, reconnect and run: tmux attach -t ${TMUX_SESSION}"
    sleep 2
    # The trailing shell keeps the session open so the final output stays on screen.
    exec tmux new-session -s "$TMUX_SESSION" \
      "$(printf '%q ' bash "$SCRIPT_PATH" --skip-prereqs "${ORIG_ARGS[@]}"); exec bash -l"
  fi
  ask_yn "Continue here without tmux?" N || exit 0
}

pc_status() { py pc status "$1" 2>/dev/null || echo 000; }

normalize_endpoint() {
  local e=${1%/} hostport
  [[ $e == http://* || $e == https://* ]] || e="https://${e}"
  hostport=${e#*://}
  [[ $hostport == *:* ]] || e="${e}:9440"
  printf '%s' "$e"
}

load_answers() {
  ANSWERS_FILE="${WORKDIR}/nkp-install.env"
  mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
  if load_config; then return 0; fi
  if [[ -f $ANSWERS_FILE ]] && ask_yn "Found answers from a previous run. Use them as defaults?" Y; then
    # shellcheck disable=SC1090
    . "$ANSWERS_FILE"
  fi
}

save_answers() {
  local k
  {
    echo "# NKP installer answers (no secrets). Generated $(date -Is)."
    for k in CLUSTER_NAME WORKSPACE_NAMESPACE NUTANIX_ENDPOINT NUTANIX_USER TLS_MODE PC_CA_FILE NUTANIX_CLUSTER SUBNET NODE_CIDR \
             VM_IMAGE STORAGE_CONTAINER_NAME CONTROLPLANE_IP SERVICE_LB_IP_RANGE POD_CIDR SERVICE_CIDR SIZING \
             CP_REPLICAS CP_VCPUS CP_MEMORY WK_REPLICAS WK_VCPUS WK_MEMORY SSH_USERNAME SSH_PUBLIC_KEY \
             USE_DOCKERHUB DOCKERHUB_USERNAME NUTANIX_REGISTRY_USERNAME USE_PROXY PROXY_HTTP PROXY_HTTPS PROXY_NO NTP_SERVERS ONBOARD_PC \
             USE_BUNDLE BUNDLE_DIR USE_CATALOG_BUNDLES USE_MGMT_REGISTRY \
             REGISTRY_MIRROR_URL REGISTRY_MIRROR_USERNAME REGISTRY_MIRROR_CACERT; do
      printf '%s=%q\n' "$k" "${!k:-}"
    done
  } >"$ANSWERS_FILE"
  chmod 600 "$ANSWERS_FILE"
}

v_workload_name() {
  v_cluster_name "$1" || return 1
  if [[ $1 == "$MGMT_CLUSTER_NAME" ]]; then echo "      That is the management cluster's name." >&2; return 1; fi
  local names
  names=$(py k8s clusters --kubeconfig "$MGMT_KCFG" 2>/dev/null | cut -f2 || true)
  if grep -qxF -- "$1" <<<"$names"; then
    echo "      A cluster named $1 already exists on ${MGMT_CLUSTER_NAME}." >&2; return 1
  fi
}

q_cluster() {
  step "Cluster name"
  if ((WORKLOAD)); then
    CLUSTER_NAME=${CLUSTER_NAME:-nkp-workload1}
    ask CLUSTER_NAME "Workload cluster name" v_workload_name
  else
    CLUSTER_NAME=${CLUSTER_NAME:-nkp-mgmt}
    ask CLUSTER_NAME "Management cluster name" v_cluster_name
  fi
  CLUSTER_DIR="${WORKDIR}/${CLUSTER_NAME}"
  mkdir -p "$CLUSTER_DIR" && chmod 700 "$CLUSTER_DIR"
}

use_insecure() {
  TLS_MODE=insecure PC_TLS=insecure TRUST_ARGS=(--insecure=true)
  warn "NKP will not verify Prism Central's TLS certificate (--insecure)."
}

fetch_server_cert() { py tls fetch "${NUTANIX_ENDPOINT#*://}" "$1"; } # out_pem -> Prism Central's own (leaf) certificate

cert_covers_host() { py tls covers "$1" "$2" 2>/dev/null; } # pem host -> 0 issued for host, 1 not, 2 cannot tell; prints its names

setup_trust() {
  local rc=0 pem tb_help b64file leaf names
  PC_TLS=insecure
  py tls probe "$NUTANIX_ENDPOINT" || rc=$?
  ((rc != 2)) || die "Cannot reach ${NUTANIX_ENDPOINT}. Check routing, firewall and DNS from the jump host."
  if ((FORCE_INSECURE)); then use_insecure; return; fi
  if ((rc == 0)); then TLS_MODE=trusted PC_TLS=trusted; ok "Prism Central certificate is trusted by this host"; return; fi
  warn "Prism Central's certificate is not trusted by this host (typical for the default self-signed certificate)."
  local modes=(insecure fetched cafile)
  local labels=("Skip certificate verification (--insecure; simplest for labs and POCs)"
                "Fetch Prism Central's certificate and trust it (it must contain ${PC_HOST})"
                "Use a CA certificate file I provide (certificate issued by an internal CA)")
  if [[ $TLS_MODE == trusted ]]; then TLS_MODE=""; fi
  TLS_MODE=${TLS_MODE:-insecure}
  pick TLS_MODE "How should NKP trust Prism Central" modes labels
  pem="${CLUSTER_DIR}/prism-central-ca.pem"
  case $TLS_MODE in
    insecure)
      use_insecure; return ;;
    fetched)
      fetch_server_cert "$pem" || die "Could not fetch the certificate from ${NUTANIX_ENDPOINT}."
      openssl x509 -in "$pem" -noout -subject -issuer -enddate -fingerprint -sha256 | sed 's/^/      /' >&2
      ask_yn "Trust this certificate?" Y || die "Certificate not trusted. Rerun and choose another option."
      PC_TLS=insecure leaf=$pem ;;
    cafile)
      ask PC_CA_FILE "Path to the CA certificate (PEM)" v_file
      openssl x509 -in "$PC_CA_FILE" -noout >/dev/null 2>&1 || die "${PC_CA_FILE} is not a PEM certificate."
      cp "$PC_CA_FILE" "$pem"
      PC_TLS=$pem leaf="${CLUSTER_DIR}/prism-central-server.pem"
      fetch_server_cert "$leaf" || leaf="" ;;
  esac
  # Trusting the issuer is not enough: NKP also requires the certificate to name the address it connects to.
  rc=0
  if [[ -n $leaf ]]; then names=$(cert_covers_host "$leaf" "$PC_HOST") || rc=$?; fi
  if ((rc == 1)); then
    warn "The certificate is not issued for ${PC_HOST} (names in it: ${names:-none}); NKP will reject it even when trusted."
    info "To verify it, rerun using one of those names as the Prism Central address, or reissue the certificate for ${PC_HOST}."
    if ask_yn "Skip certificate verification (--insecure) instead?" Y; then use_insecure; return; fi
    die "Prism Central's certificate does not cover ${PC_HOST}. Rerun with an address it covers, or with --insecure."
  fi
  if (($(wc -c <"$pem") > 12000)); then
    warn "The certificate file is large; node cloud-init data is limited to 16 KB. Pass only the CA, not a bundle."
  fi
  b64file="${CLUSTER_DIR}/prism-central-ca.b64"
  base64 -w0 <"$pem" >"$b64file"
  tb_help=$(nkp create cluster nutanix --help 2>&1 | grep -i -- '--additional-trust-bundle' || true)
  [[ -n $tb_help ]] || die "This nkp CLI has no --additional-trust-bundle flag. Rerun and choose --insecure, or update the CLI."
  if grep -qiE 'file|path' <<<"$tb_help"; then
    TRUST_ARGS=(--additional-trust-bundle="$b64file")
  else
    TRUST_ARGS=(--additional-trust-bundle="$(cat "$b64file")")
  fi
  info "nkp help: ${tb_help#"${tb_help%%[![:space:]]*}"}"
}

q_prism_central() {
  step "Prism Central"
  local code i
  ask NUTANIX_ENDPOINT "Prism Central address (host, host:port or https://host:port)" v_endpoint
  NUTANIX_ENDPOINT=$(normalize_endpoint "$NUTANIX_ENDPOINT")
  PC_HOST=${NUTANIX_ENDPOINT#*://}; PC_HOST=${PC_HOST%:*}
  info "Using ${NUTANIX_ENDPOINT}"
  setup_trust
  ask NUTANIX_USER "Prism Central username (service account with the NKP role)"
  for i in 1 2 3; do
    ask_secret NUTANIX_PASSWORD "Prism Central password"
    code=$(pc_status /api/nutanix/v3/users/me)
    case $code in
      200)     ok "Logged in to Prism Central as ${NUTANIX_USER}"; PC_API_OK=1; return ;;
      401|403) warn "Login failed (HTTP ${code})."; NUTANIX_PASSWORD=""; ((i < 3)) || die "Too many failed logins." ;;
      *)       warn "Unexpected response (HTTP ${code}) from the Prism Central API; continuing without inventory lookups."
               PC_API_OK=0; return ;;
    esac
  done
}

q_inventory() {
  step "Prism Central resources"
  local pe_names=() pe_uuids=() subnet_vals=() subnet_labels=() subnet_uuids=() subnet_cidrs=() subnet_pools=()
  local img_all=() img_list=() sc_list=() name uuid label cidr pools i
  SUBNET_UUID="" PE_UUID=""
  if ((PC_API_OK)); then
    while IFS=$'\t' read -r name uuid; do
      if [[ -n $name ]]; then pe_names+=("$name"); pe_uuids+=("$uuid"); fi
    done < <(py pc clusters 2>/dev/null | sort || true)
  fi
  pick NUTANIX_CLUSTER "Prism Element cluster for the nodes" pe_names
  for i in "${!pe_names[@]}"; do
    if [[ ${pe_names[$i]} == "$NUTANIX_CLUSTER" ]]; then PE_UUID=${pe_uuids[$i]}; fi
  done

  if ((PC_API_OK)); then
    while IFS=$'\t' read -r name uuid label cidr pools; do
      if [[ -n $name ]]; then
        subnet_vals+=("$name") subnet_uuids+=("$uuid") subnet_labels+=("$label") subnet_cidrs+=("$cidr") subnet_pools+=("$pools")
      fi
    done < <(py pc subnets "$NUTANIX_CLUSTER" 2>/dev/null || true)
  fi
  default_match SUBNET subnet_vals '^primary(-|$)'
  pick SUBNET "Subnet for control plane and worker nodes (must have IPAM or DHCP)" subnet_vals subnet_labels

  NODE_POOLS=""
  for i in "${!subnet_vals[@]}"; do
    [[ ${subnet_vals[$i]} == "$SUBNET" ]] || continue
    SUBNET_UUID=${subnet_uuids[$i]}
    if [[ -n ${subnet_cidrs[$i]} ]]; then
      NODE_CIDR=${subnet_cidrs[$i]} NODE_POOLS=${subnet_pools[$i]}
      ok "Subnet ${SUBNET}: ${NODE_CIDR}${NODE_POOLS:+, IPAM pool ${NODE_POOLS}}"
    fi
    break
  done
  if [[ -z $NODE_POOLS ]]; then
    info "No Nutanix IPAM pool found for ${SUBNET} (external DHCP?). IP checks will use the CIDR only."
    ask NODE_CIDR "Node subnet CIDR, for IP validation (leave blank to skip)" optional
    if [[ -n $NODE_CIDR ]] && ! v_cidr "$NODE_CIDR"; then NODE_CIDR=""; fi
  fi

  if ((PC_API_OK)); then
    mapfile -t img_all < <(py pc images 2>/dev/null || true)
    mapfile -t img_list < <(printf '%s\n' "${img_all[@]}" | grep -F -- "$K8S_VERSION_HINT" || true)
    if ((${#img_list[@]} == 0 && ${#img_all[@]} > 0)); then
      warn "No image name contains Kubernetes ${K8S_VERSION_HINT}; the NKP preflight check expects the version in the name. Showing all images."
      img_list=("${img_all[@]}")
    fi
  fi
  pick VM_IMAGE "Node OS image (Nutanix pre-built NKP image, not renamed)" img_list
  [[ $VM_IMAGE == *"$K8S_VERSION_HINT"* ]] || warn "'${VM_IMAGE}' does not contain ${K8S_VERSION_HINT}; preflight may reject it."

  if ((PC_API_OK)); then
    mapfile -t sc_list < <(py pc containers "$NUTANIX_CLUSTER" 2>/dev/null || true)
  fi
  default_match STORAGE_CONTAINER_NAME sc_list '^default$'
  default_match STORAGE_CONTAINER_NAME sc_list '^default'
  pick STORAGE_CONTAINER_NAME "Storage container for Kubernetes persistent volumes (on ${NUTANIX_CLUSTER})" sc_list
}

# ---------------------------------------------------------------------------
# Lab network: addresses reserved at the end of the IPAM pool, DHCP DNS from the AutoAD VM
# ---------------------------------------------------------------------------

IP_PLAN_MAX=30           # management API + workload API + two load balancer ranges of 14
IP_PLAN_MIN=12           # never fewer: 1 + 1 + 5 + 5
IP_PLAN_NODE_RESERVE=20  # pool addresses left for node VMs (both clusters plus rolling upgrades)

ip_plan_file() { printf '%s' "${WORKDIR}/nkp-ip-plan.env"; }

ip_plan_get() { # KEY -> its value in the IP plan file, without touching the caller's variables
  local f; f=$(ip_plan_file)
  [[ -f $f ]] || return 0
  # shellcheck disable=SC1090
  (. "$f"; printf '%s' "${!1:-}")
}

ip_plan_default() { # VAR KEY: take the plan's value unless VAR already holds addresses inside the reserved block
  local block val cur=${!1:-} r
  block=$(ip_plan_get IP_PLAN_BLOCK) val=$(ip_plan_get "$2")
  [[ -n $block && -n $val ]] || return 0
  [[ -z ${SUBNET:-} || $(ip_plan_get IP_PLAN_SUBNET) == "$SUBNET" ]] || return 0
  if [[ -n $cur ]]; then
    r=$cur
    [[ $r == *-* ]] || r="${r}-${r}"
    if ipcalc range_in_ranges "$r" "$block"; then return 0; fi
  fi
  printf -v "$1" '%s' "$val"
}

lab_network() { # management run, between q_inventory and q_network
  step "Lab network: addresses for NKP and DNS"
  local f k rc=0 dhcp=keep now
  local IP_PLAN_COUNT IP_PLAN_BLOCK IP_PLAN_NEW_POOLS MGMT_CONTROLPLANE_IP WL_CONTROLPLANE_IP MGMT_LB_RANGE WL_LB_RANGE
  local POOLS="" DNS_VM_IP="" DNS_OK=N
  local IP_PLAN_SUBNET=$SUBNET IP_PLAN_SUBNET_UUID=$SUBNET_UUID IP_PLAN_ORIGINAL_POOLS IP_PLAN_ORIGINAL_DHCP IP_PLAN_DNS="" IP_PLAN_DOMAIN=""
  f=$(ip_plan_file)
  if ((NO_IP_PLAN)); then info "--no-ip-plan: the subnet's IPAM pool and DHCP options stay as they are."; return 0; fi
  if ((!PC_API_OK)) || [[ -z $SUBNET_UUID ]]; then warn "Prism Central API not available; skipping the IP plan."; return 0; fi
  if [[ -f $f && $(ip_plan_get IP_PLAN_SUBNET_UUID) == "$SUBNET_UUID" ]] \
     && ! ipcalc range_overlaps "$(ip_plan_get IP_PLAN_BLOCK)" "$NODE_POOLS"; then
    ok "Reusing ${f}: $(ip_plan_get IP_PLAN_BLOCK) is already outside the IPAM pool of ${SUBNET}"
    return 0
  fi
  info "Checking which addresses of ${SUBNET} are in use (VMs, hosts, ping)..."
  py_vars pc ip-plan "$SUBNET_UUID" --pc-host "$PC_HOST" --max "$IP_PLAN_MAX" --min "$IP_PLAN_MIN" \
    --reserve "$IP_PLAN_NODE_RESERVE" --dns-vm "$LAB_DNS_VM" --domain "$LAB_DOMAIN" || rc=$?
  case $rc in
    0) ;;
    3) warn "${SUBNET} has no IPAM pool; nothing to reserve. Enter the addresses yourself."; return 0 ;;
    4) die "The IPAM pool of ${SUBNET} has no run of ${IP_PLAN_MIN} free addresses (keeping ${IP_PLAN_NODE_RESERVE} for nodes). Free some, or rerun with --no-ip-plan." ;;
    5) die "Could not find a block of addresses that nobody answers on. Rerun with --no-ip-plan." ;;
    *) warn "Could not read subnet ${SUBNET}; skipping the IP plan."; return 0 ;;
  esac

  if [[ -z $DNS_VM_IP ]]; then
    warn "No VM named '${LAB_DNS_VM}' with an IPv4 address; the subnet's DNS settings stay unchanged."
  elif [[ $DNS_OK != Y ]]; then
    warn "${LAB_DNS_VM} (${DNS_VM_IP}) does not resolve ${LAB_DOMAIN}; the subnet's DNS settings stay unchanged."
  else
    ok "${LAB_DNS_VM} (${DNS_VM_IP}) resolves ${LAB_DOMAIN}"
    IP_PLAN_DNS=$DNS_VM_IP IP_PLAN_DOMAIN=$LAB_DOMAIN
    dhcp="merge:$(jq -nc --arg ip "$DNS_VM_IP" --arg d "$LAB_DOMAIN" '{domain_name_server_list: [$ip], domain_name: $d, domain_search_list: [$d]}')"
  fi

  row "IPAM pool of ${SUBNET}" "$POOLS"
  row "Reserve for NKP" "${IP_PLAN_BLOCK} (${IP_PLAN_COUNT} addresses)"
  row "New IPAM pool" "${IP_PLAN_NEW_POOLS:-none}"
  row "Management cluster" "API ${MGMT_CONTROLPLANE_IP}, load balancer ${MGMT_LB_RANGE}"
  row "Workload cluster" "API ${WL_CONTROLPLANE_IP}, load balancer ${WL_LB_RANGE}"
  if [[ -n $IP_PLAN_DNS ]]; then row "DHCP DNS server / domain" "${IP_PLAN_DNS} / ${IP_PLAN_DOMAIN}"; fi
  if ! ask_yn "Apply this to subnet ${SUBNET} in Prism Central (undone by --destroy)?" Y; then
    info "Subnet unchanged. Enter addresses outside the IPAM pool yourself."
    return 0
  fi

  (
    umask 077
    echo "# NKP IP plan written $(date -Is). ${SCRIPT_PATH} --destroy restores the original pool and DHCP options."
    for k in IP_PLAN_SUBNET IP_PLAN_SUBNET_UUID IP_PLAN_ORIGINAL_POOLS IP_PLAN_ORIGINAL_DHCP IP_PLAN_NEW_POOLS IP_PLAN_BLOCK \
             IP_PLAN_COUNT IP_PLAN_DNS IP_PLAN_DOMAIN MGMT_CONTROLPLANE_IP WL_CONTROLPLANE_IP MGMT_LB_RANGE WL_LB_RANGE; do
      printf '%s=%q\n' "$k" "${!k}"
    done
  ) >"$f"
  chmod 600 "$f"
  if ! now=$(py pc subnet-set "$SUBNET_UUID" --pools "$IP_PLAN_NEW_POOLS" --dhcp "$dhcp"); then
    rm -f "$f"
    die "The subnet was not changed. Rerun, or use --no-ip-plan and enter addresses yourself."
  fi
  if [[ $now == "$IP_PLAN_NEW_POOLS" ]]; then ok "IPAM pool of ${SUBNET} is now ${now:-empty}; plan saved to ${f}"
  else warn "The IPAM pool reads back as '${now}', expected '${IP_PLAN_NEW_POOLS}'. Check the subnet in Prism Central."; fi
  NODE_POOLS=$IP_PLAN_NEW_POOLS
}

q_network() { # [ips-only]
  step "Cluster IP addresses${CLUSTER_NAME:+ for ${CLUSTER_NAME}}"
  local tries=0 prefix=MGMT
  if ((WORKLOAD)) || [[ ${1-} == ips-only ]]; then prefix=WL; fi
  ip_plan_default CONTROLPLANE_IP "${prefix}_CONTROLPLANE_IP"
  ip_plan_default SERVICE_LB_IP_RANGE "${prefix}_LB_RANGE"
  info "Both values below must be static, unused, and outside the subnet's IPAM/DHCP pool."
  while :; do
    retry_guard tries
    ask CONTROLPLANE_IP "Kubernetes API (control plane endpoint) IP" v_ip
    if [[ -n $NODE_POOLS ]] && ipcalc ip_in_ranges "$CONTROLPLANE_IP" "$NODE_POOLS"; then
      warn "${CONTROLPLANE_IP} is inside the IPAM pool ${NODE_POOLS}."; continue
    fi
    if [[ -n $RESERVED_RANGES ]] && ipcalc ip_in_ranges "$CONTROLPLANE_IP" "$RESERVED_RANGES"; then
      warn "${CONTROLPLANE_IP} is already used by another NKP cluster (${RESERVED_RANGES})."; continue
    fi
    if [[ -n $NODE_CIDR ]] && ! ipcalc ip_in_cidr "$CONTROLPLANE_IP" "$NODE_CIDR"; then
      warn "${CONTROLPLANE_IP} is outside the node subnet ${NODE_CIDR}."
      ask_yn "Use it anyway?" N || continue
    fi
    if ip_responds "$CONTROLPLANE_IP"; then
      warn "${CONTROLPLANE_IP} answers ping, so something already uses it."
      ask_yn "Use it anyway?" N || continue
    fi
    break
  done
  tries=0
  while :; do
    retry_guard tries
    ask SERVICE_LB_IP_RANGE "Load balancer IP range for services (first-last; the NKP UI takes the first IP)" v_range
    if [[ -n $NODE_POOLS ]] && ipcalc range_overlaps "$SERVICE_LB_IP_RANGE" "$NODE_POOLS"; then
      warn "The range overlaps the IPAM pool ${NODE_POOLS}."; continue
    fi
    if ipcalc ip_in_ranges "$CONTROLPLANE_IP" "$SERVICE_LB_IP_RANGE"; then
      warn "The range contains the control plane IP ${CONTROLPLANE_IP}."; continue
    fi
    if [[ -n $RESERVED_RANGES ]] && ipcalc range_overlaps "$SERVICE_LB_IP_RANGE" "$RESERVED_RANGES"; then
      warn "The range overlaps addresses another NKP cluster uses (${RESERVED_RANGES})."; continue
    fi
    if [[ -n $NODE_CIDR ]] && ! ipcalc range_in_cidr "$SERVICE_LB_IP_RANGE" "$NODE_CIDR"; then
      warn "The range is not inside ${NODE_CIDR}. MetalLB needs addresses on the nodes' layer-2 subnet."
      ask_yn "Use it anyway?" N || continue
    fi
    local first; first=$(ipcalc range_first "$SERVICE_LB_IP_RANGE")
    if ip_responds "$first"; then
      warn "${first} answers ping, so something already uses it."
      ask_yn "Use the range anyway?" N || continue
    fi
    break
  done
  [[ ${1-} != ips-only ]] || return 0
  POD_CIDR=${POD_CIDR:-192.168.0.0/16}
  SERVICE_CIDR=${SERVICE_CIDR:-10.96.0.0/12}
  info "Pod and service networks are internal to the cluster and cannot be changed later."
  tries=0
  while :; do
    retry_guard tries
    ask POD_CIDR "Kubernetes pod network CIDR" v_cidr
    ask SERVICE_CIDR "Kubernetes service network CIDR" v_cidr
    if ipcalc cidr_overlap "$POD_CIDR" "$SERVICE_CIDR"; then warn "Pod and service networks overlap."; continue; fi
    if [[ -n $NODE_CIDR ]] && { ipcalc cidr_overlap "$POD_CIDR" "$NODE_CIDR" || ipcalc cidr_overlap "$SERVICE_CIDR" "$NODE_CIDR"; }; then
      warn "Pod or service network overlaps the node subnet ${NODE_CIDR}."; continue
    fi
    if ipcalc ip_in_cidr "$CONTROLPLANE_IP" "$POD_CIDR" || ipcalc ip_in_cidr "$CONTROLPLANE_IP" "$SERVICE_CIDR"; then
      warn "The control plane IP falls inside the pod or service network."; continue
    fi
    if ipcalc ip_in_cidr "$PC_HOST" "$POD_CIDR" 2>/dev/null || ipcalc ip_in_cidr "$PC_HOST" "$SERVICE_CIDR" 2>/dev/null; then
      warn "Prism Central (${PC_HOST}) falls inside the pod or service network; the cluster could not reach it."; continue
    fi
    break
  done
}

q_sizing() { # [workload]
  local kind=${1:-management}
  step "Node sizing"
  local vals=(pro starter custom)
  local labels=("Pro/Ultimate default: 3 control plane (4 vCPU, 16 GiB) + 4 workers (8 vCPU, 32 GiB)"
                "Starter: 3 control plane (2 vCPU, 8 GiB) + ${MIN_WORKERS} workers (4 vCPU, 8 GiB)"
                "Custom (at least ${MIN_WORKERS} workers)")
  SIZING=${SIZING:-pro}
  pick SIZING "Choose a size" vals labels
  SIZING_ARGS=()
  case $SIZING in
    starter)
      SIZING_ARGS=(--control-plane-vcpus=2 --control-plane-memory=8 --worker-replicas="$MIN_WORKERS" --worker-vcpus=4 --worker-memory=8)
      warn "4 vCPU / 8 GiB workers cannot run the extra Pro/Ultimate platform apps if you upgrade the license later." ;;
    custom)
      CP_REPLICAS=${CP_REPLICAS:-3} CP_VCPUS=${CP_VCPUS:-4} CP_MEMORY=${CP_MEMORY:-16}
      WK_REPLICAS=${WK_REPLICAS:-$MIN_WORKERS} WK_VCPUS=${WK_VCPUS:-8} WK_MEMORY=${WK_MEMORY:-32}
      if ((10#$WK_REPLICAS < MIN_WORKERS)); then WK_REPLICAS=$MIN_WORKERS; fi
      ask CP_REPLICAS "Control plane nodes (1, 3 or 5)" v_cp_replicas
      ask CP_VCPUS "Control plane vCPUs per node" v_int
      ask CP_MEMORY "Control plane memory per node (GiB)" v_int
      ask WK_REPLICAS "Worker nodes (at least ${MIN_WORKERS})" v_workers
      ask WK_VCPUS "Worker vCPUs per node" v_int
      ask WK_MEMORY "Worker memory per node (GiB)" v_int
      ((CP_REPLICAS >= 3)) || warn "A single control plane node means losing the node loses the cluster."
      SIZING_ARGS=(--control-plane-replicas="$CP_REPLICAS" --control-plane-vcpus="$CP_VCPUS" --control-plane-memory="$CP_MEMORY"
                   --worker-replicas="$WK_REPLICAS" --worker-vcpus="$WK_VCPUS" --worker-memory="$WK_MEMORY") ;;
  esac
  if [[ $kind == management && $SIZING == starter ]]; then
    warn "Starter nodes (2 vCPU / 8 GiB control plane, 4 vCPU / 8 GiB workers) are too small for a management cluster:"
    warn "Kommander times out (KommanderInitialized) and there is no room for Harbor and Rook Ceph."
    ask_yn "Use Starter sizing for the management cluster anyway?" N \
      || die "Set SIZING=pro (or custom with workers of at least 8 vCPU / 32 GiB) and rerun."
  fi
  if [[ $SIZING == starter && ${VM_IMAGE,,} != *rocky* ]]; then
    warn "The Starter license supports Rocky Linux images only; '${VM_IMAGE}' needs Pro or Ultimate."
  fi
}

bundle_candidates() { # -> container-images directories of extracted NKP packages (nkp-bundle_* or nkp-air-gapped-bundle_*), newest first
  local d
  for d in "${HOME}/nkp-dist" "$HOME"; do
    find "$d" -maxdepth 3 -type d -path "*/nkp-v${NKP_MINOR}.*/container-images" 2>/dev/null || true
  done | sort -rV | awk '!seen[$0]++'
}

bundle_files() { # container-images dir -> comma-separated tars for --bundle or nkp push bundle; exit 1 with the reason when incomplete
  local dir=$1 f name out=() ver_re="-v?${NKP_MINOR//./\\.}(\.[0-9]+)?(-airgapped)?\.tar$"
  for name in konvoy-image-bundle kommander-image-bundle nkp-release-specs; do
    f=$(find "$dir" -maxdepth 1 -type f -name "${name}-*.tar" 2>/dev/null | sort -V | awk 'END {print}')
    if [[ -z $f ]]; then
      if [[ $name == k* ]]; then echo "      ${dir} has no ${name}-*.tar." >&2; return 1; fi
      continue
    fi
    if [[ ! $(basename "$f") =~ $ver_re ]]; then
      echo "      $(basename "$f") is not an NKP ${NKP_MINOR} bundle." >&2; return 1
    fi
    out+=("$f")
  done
  if [[ ${USE_CATALOG_BUNDLES:-Y} == Y ]]; then
    while IFS= read -r f; do
      if [[ $(basename "$f") =~ $ver_re ]]; then out+=("$f"); else echo "      Skipping $(basename "$f"): not for NKP ${NKP_MINOR}." >&2; fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*catalog*.tar' 2>/dev/null | sort)
  fi
  local IFS=,
  printf '%s' "${out[*]}"
}

v_bundle_dir() {
  [[ -d $1 ]] || { echo "      Not a directory: $1" >&2; return 1; }
  bundle_files "$1" >/dev/null
}

q_bundle() { # management cluster: seed its internal registry (NCR) from the air-gapped bundle
  BUNDLE_ARGS=() BUNDLE_COUNT=0 BUNDLE_FILES=""
  if [[ -n $BUNDLE_DIR_ARG ]]; then BUNDLE_DIR=$BUNDLE_DIR_ARG USE_BUNDLE=Y; fi
  if [[ ${USE_BUNDLE:-} == N ]]; then info "Image bundle: not used (USE_BUNDLE=N); images come from the internet."; return 0; fi
  if [[ -z ${BUNDLE_DIR:-} || ! -d $BUNDLE_DIR ]]; then BUNDLE_DIR=$(bundle_candidates | awk 'NR == 1'); fi
  if [[ -z $BUNDLE_DIR && ${USE_BUNDLE:-} != Y ]]; then
    info "No extracted nkp-v${NKP_MINOR}.x/container-images under ${HOME}/nkp-dist or ${HOME}: images come from the internet (Docker Hub)."
    info "For a local registry, rerun with --package nkp-bundle_v${NKP_MINOR}.x_linux_amd64.tar.gz (or --bundle-dir DIR)."
    USE_BUNDLE=N
    return 0
  fi
  step "Image bundle (internal registry)"
  if [[ $(nkp create cluster nutanix --help 2>&1 || true) != *--bundle* ]]; then
    ((!UNATTENDED)) || [[ ${USE_BUNDLE:-} != Y ]] || die "--unattended: USE_BUNDLE=Y, but this nkp CLI has no --bundle option."
    warn "This nkp CLI has no --bundle option; images come from the internet."
    USE_BUNDLE=N
    return 0
  fi
  info "${CLUSTER_NAME} is created with --bundle: NKP loads the images into its internal registry mirror. After that, the script"
  info "deploys Harbor on ${CLUSTER_NAME}, pushes the same bundles into Harbor project ${HARBOR_PROJECT}, and workload clusters pull from there."
  if ! ask_yn "Create ${CLUSTER_NAME} from the bundle?" "${USE_BUNDLE:-Y}"; then USE_BUNDLE=N; return 0; fi
  USE_BUNDLE=Y
  ask BUNDLE_DIR "Bundle directory (container-images)" v_bundle_dir
  BUNDLE_DIR=$(readlink -f "$BUNDLE_DIR")
  local files f parts names=() catalogs
  catalogs=$(find "$BUNDLE_DIR" -maxdepth 1 -type f -name '*catalog*.tar' -exec basename {} \; 2>/dev/null | sort | paste -sd' ' - || true)
  if [[ -n $catalogs ]]; then
    if ask_yn "Also seed the catalog application bundles (${catalogs})?" "${USE_CATALOG_BUNDLES:-Y}"; then
      USE_CATALOG_BUNDLES=Y
    else
      USE_CATALOG_BUNDLES=N
    fi
  fi
  files=$(bundle_files "$BUNDLE_DIR")
  IFS=, read -r -a parts <<<"$files"
  for f in "${parts[@]}"; do names+=("$(basename "$f")"); done
  BUNDLE_ARGS=(--bundle="$files") BUNDLE_COUNT=${#parts[@]} BUNDLE_FILES=$files
  ok "Bundle: ${names[*]}"
}

q_access() {
  step "Node SSH access"
  SSH_USERNAME=${SSH_USERNAME:-nkpadmin}
  ask SSH_USERNAME "SSH username to create on every node"
  local k
  if [[ -z ${SSH_PUBLIC_KEY:-} ]]; then
    for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
      if [[ -r $k ]]; then SSH_PUBLIC_KEY=$k; break; fi
    done
  fi
  if [[ -z ${SSH_PUBLIC_KEY:-} ]] && ask_yn "No SSH key found. Generate ~/.ssh/id_ed25519 now?" Y; then
    ssh-keygen -q -t ed25519 -N "" -C "nkp-${CLUSTER_NAME}" -f "$HOME/.ssh/id_ed25519"
    SSH_PUBLIC_KEY="$HOME/.ssh/id_ed25519.pub"
  fi
  ask SSH_PUBLIC_KEY "SSH public key file" v_file

  # A connected --self-managed cluster without a registry mirror requires these; with the bundle they are optional.
  NUTANIX_REGISTRY_ARGS=()
  local create_help tok=N
  create_help=$(nkp create cluster nutanix --help 2>&1 || true)
  if ((WORKLOAD)); then
    info "Nutanix registry: workload clusters inherit the access token from ${MGMT_CLUSTER_NAME}."
  elif [[ $create_help == *--nutanix-registry-username* ]]; then
    if ((${#BUNDLE_ARGS[@]})); then
      step "Nutanix registry (optional: the bundle seeds the internal registry)"
      if [[ -n ${NUTANIX_REGISTRY_PASSWORD:-} ]]; then tok=Y; fi
    else
      step "Nutanix registry (required)"
    fi
    if ((${#BUNDLE_ARGS[@]} == 0)) || ask_yn "Also provide the Nutanix Docker Hub token (for images outside the bundle)?" "$tok"; then
      info "NKP pulls its images with a Docker Hub service account issued on the Nutanix Portal."
      info "Portal: NKP download page > generate an access token (the page shows: docker login --username svcregistrynkp)."
      NUTANIX_REGISTRY_USERNAME=${NUTANIX_REGISTRY_USERNAME:-$NUTANIX_REGISTRY_DEFAULT_USER}
      ask_registry_login NUTANIX_REGISTRY_USERNAME NUTANIX_REGISTRY_PASSWORD "Nutanix registry" "Access token from the Nutanix Portal"
      NUTANIX_REGISTRY_ARGS=(--nutanix-registry-username="$NUTANIX_REGISTRY_USERNAME"
                             --nutanix-registry-password="$NUTANIX_REGISTRY_PASSWORD")
    fi
  fi

  step "Your own Docker Hub account (optional)"
  info "Separate from the Nutanix registry token above. Only needed to lift Docker Hub pull limits for other images."
  local def=Y
  if ((${#NUTANIX_REGISTRY_ARGS[@]} || ${#BUNDLE_ARGS[@]} || ${#REGISTRY_MIRROR_ARGS[@]})); then def=N; fi
  if ask_yn "Provide your own Docker Hub credentials?" "${USE_DOCKERHUB:-$def}"; then
    USE_DOCKERHUB=Y
    ask_registry_login DOCKERHUB_USERNAME DOCKERHUB_PASSWORD "Docker Hub" "Docker Hub password or access token"
  else
    USE_DOCKERHUB=N
  fi
}

dockerhub_login_check() { # user token -> 0 accepted, 1 rejected, 2 could not check
  local cfg out rc=0
  cfg=$(mktemp -d)
  out=$(printf '%s' "$2" | DOCKER_CONFIG="$cfg" docker login --username "$1" --password-stdin 2>&1) || rc=$?
  rm -rf "$cfg"
  ((rc == 0)) && return 0
  if grep -qiE 'unauthorized|incorrect username or password|denied' <<<"$out"; then return 1; fi
  warn "Could not verify the login with Docker Hub: ${out##*$'\n'}"
  return 2
}

ask_registry_login() { # USER_VAR SECRET_VAR "Label" "Secret prompt"
  local user_var=$1 secret_var=$2 label=$3 secret_prompt=$4 rc i
  ask "$user_var" "${label} username"
  for i in 1 2 3; do
    ask_secret "$secret_var" "$secret_prompt"
    dockerhub_login_check "${!user_var}" "${!secret_var}" && rc=0 || rc=$?
    case $rc in
      0) ok "${label} login accepted for ${!user_var}"; return ;;
      2) ask_yn "Use these credentials without verification?" Y && return ;;
      1) warn "Docker Hub rejected the ${label} login for ${!user_var}." ;;
    esac
    printf -v "$secret_var" '%s' ""
    if ((i < 3)) && ask_yn "Change the username (currently ${!user_var})?" N; then ask "$user_var" "${label} username"; fi
  done
  die "${label} login failed three times. Check the token on the Nutanix Portal and rerun with --skip-prereqs."
}

q_extras() {
  step "Proxy, NTP and Prism Central onboarding"
  local env_proxy=${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}
  local def=N
  if [[ -n $env_proxy || ${USE_PROXY:-} == Y ]]; then def=Y; fi
  if ask_yn "Do the cluster nodes need an HTTP(S) proxy to reach the internet?" "$def"; then
    USE_PROXY=Y
    PROXY_HTTP=${PROXY_HTTP:-${HTTP_PROXY:-${http_proxy:-}}}
    ask PROXY_HTTP "HTTP proxy URL (http://host:port)"
    PROXY_HTTPS=${PROXY_HTTPS:-${HTTPS_PROXY:-${https_proxy:-$PROXY_HTTP}}}
    ask PROXY_HTTPS "HTTPS proxy URL"
    local auto="localhost,127.0.0.1,${POD_CIDR},${SERVICE_CIDR}${NODE_CIDR:+,$NODE_CIDR},${CONTROLPLANE_IP},${PC_HOST},kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.default.svc.cluster.local,.svc,.svc.cluster,.svc.cluster.local,169.254.169.254"
    PROXY_NO=${PROXY_NO:-$auto}
    ask PROXY_NO "No-proxy list"
  else
    USE_PROXY=N
  fi
  if [[ -z ${NTP_SERVERS:-} ]] && ((PC_API_OK)); then
    NTP_SERVERS=$(py pc ntp "$NUTANIX_CLUSTER" 2>/dev/null || true)
    [[ -z $NTP_SERVERS ]] || info "Prism Central uses NTP ${NTP_SERVERS}"
  fi
  ask NTP_SERVERS "NTP servers, comma-separated (blank = keep the image defaults)" optional
  if ask_yn "Register the cluster in Prism Central (NKP default)?" "${ONBOARD_PC:-Y}"; then ONBOARD_PC=Y; else ONBOARD_PC=N; fi
}

CVM_RESERVE_GIB=32  # memory per host taken by the CVM, which the VM list does not show
NODE_DISK_GIB=80

sizing_need() { # -> "nodes vcpus memory_gib" for the current SIZING values
  case $SIZING in
    pro)     echo "$((3 + 4)) $((3 * 4 + 4 * 8)) $((3 * 16 + 4 * 32))" ;;
    starter) echo "$((3 + MIN_WORKERS)) $((3 * 2 + MIN_WORKERS * 4)) $((3 * 8 + MIN_WORKERS * 8))" ;;
    *)       echo "$((CP_REPLICAS + WK_REPLICAS)) $((CP_REPLICAS * CP_VCPUS + WK_REPLICAS * WK_VCPUS))" \
                  "$((CP_REPLICAS * CP_MEMORY + WK_REPLICAS * WK_MEMORY))" ;;
  esac
}

capacity_check() { # nodes vcpus memory_gib: everything this run will create on NUTANIX_CLUSTER
  step "Capacity of ${NUTANIX_CLUSTER}"
  local nodes=$1 vcpus=$2 mem=$3 disk=$(($1 * NODE_DISK_GIB)) cvm free usable registry=""
  local HOSTS="" CORES=0 HOST_MEM_GIB=0 VM_VCPU=0 VM_MEM_GIB=0 SC_FREE_GIB="" VMS_OK=N
  if ((${#BUNDLE_ARGS[@]})); then disk=$((disk + HARBOR_DISK_GIB)) registry=" (incl. ${HARBOR_DISK_GIB} GiB of Rook Ceph volumes for Harbor)"; fi
  if ((!PC_API_OK)) || [[ -z ${PE_UUID:-} ]]; then warn "Prism Central API not available; skipping the capacity check."; return 0; fi
  py_vars pc capacity "$PE_UUID" "$STORAGE_CONTAINER_NAME" 2>/dev/null || true
  if [[ -z $HOSTS ]] || ((HOSTS == 0 || HOST_MEM_GIB == 0)); then
    warn "Could not read the hosts of ${NUTANIX_CLUSTER}; skipping the capacity check."
    return 0
  fi
  [[ $VMS_OK == Y ]] || warn "Could not list the VMs; assuming the cluster is empty."
  cvm=$((HOSTS * CVM_RESERVE_GIB))
  free=$((HOST_MEM_GIB - VM_MEM_GIB - cvm))
  usable=$((free * 90 / 100))
  row "Hosts" "${HOSTS}: ${CORES} cores, ${HOST_MEM_GIB} GiB memory"
  row "Running VMs" "${VM_VCPU} vCPU, ${VM_MEM_GIB} GiB (CVMs about ${cvm} GiB)"
  row "NKP adds" "${nodes} VMs: ${vcpus} vCPU, ${mem} GiB memory, ${disk} GiB disk${registry}"
  if ((CORES > 0 && VM_VCPU + vcpus > CORES * 4)); then
    warn "vCPU overcommit would be $(((VM_VCPU + vcpus) / CORES)):1, above 4:1. Expect slow platform applications."
  fi
  if [[ -n $SC_FREE_GIB ]] && ((disk > SC_FREE_GIB)); then
    warn "Storage container ${STORAGE_CONTAINER_NAME} has about ${SC_FREE_GIB} GiB free; NKP takes up to ${disk} GiB${registry} (thin provisioned)."
  elif [[ -n $SC_FREE_GIB ]]; then
    ok "Storage: ${disk} GiB${registry}, about ${SC_FREE_GIB} GiB free in ${STORAGE_CONTAINER_NAME}"
  fi
  if ((mem > usable)); then
    warn "Not enough memory: NKP needs ${mem} GiB, about ${usable} GiB is free after the CVMs and a 10% margin."
    ask_yn "Continue anyway?" N || die "Choose a smaller size (Starter) or free memory on ${NUTANIX_CLUSTER}, then rerun."
  else
    ok "Memory: ${mem} GiB needed, about ${usable} GiB free"
  fi
}

build_command() {
  if ((${#BUNDLE_ARGS[@]} && ${#REGISTRY_MIRROR_ARGS[@]})); then
    die "--bundle and --registry-mirror-* cannot be combined (NKP ${NKP_MINOR} docs)."
  fi
  CMD=(nkp create cluster nutanix)
  if ((WORKLOAD)); then
    CMD+=(--namespace="$WORKSPACE_NAMESPACE" --kubeconfig="$MGMT_KCFG")
  else
    CMD+=(--self-managed)
  fi
  CMD+=(
    --cluster-name="$CLUSTER_NAME"
    --endpoint="$NUTANIX_ENDPOINT"
    "${TRUST_ARGS[@]}"
    --control-plane-endpoint-ip="$CONTROLPLANE_IP"
    --csi-storage-container="$STORAGE_CONTAINER_NAME"
    --kubernetes-pod-network-cidr="$POD_CIDR"
    --kubernetes-service-cidr="$SERVICE_CIDR"
    --kubernetes-service-load-balancer-ip-range="$SERVICE_LB_IP_RANGE"
    --control-plane-prism-element-cluster="$NUTANIX_CLUSTER"
    --control-plane-subnets="$SUBNET"
    --control-plane-vm-image="$VM_IMAGE"
    --worker-prism-element-cluster="$NUTANIX_CLUSTER"
    --worker-subnets="$SUBNET"
    --worker-vm-image="$VM_IMAGE"
    --ssh-username="$SSH_USERNAME"
    --ssh-public-key-file="$SSH_PUBLIC_KEY"
    --timeout=60m
    "${SIZING_ARGS[@]}"
    "${NUTANIX_REGISTRY_ARGS[@]}"
    "${BUNDLE_ARGS[@]}"
    "${REGISTRY_MIRROR_ARGS[@]}")
  if [[ $USE_DOCKERHUB == Y ]]; then
    CMD+=(--registry-url="$DOCKERHUB_URL" --registry-username="$DOCKERHUB_USERNAME" --registry-password="$DOCKERHUB_PASSWORD")
  fi
  if [[ $USE_PROXY == Y ]]; then
    CMD+=(--http-proxy="$PROXY_HTTP" --https-proxy="$PROXY_HTTPS" --no-proxy="$PROXY_NO")
  fi
  [[ -z $NTP_SERVERS ]] || CMD+=(--ntp-servers="$NTP_SERVERS")
  [[ $ONBOARD_PC == Y ]] || CMD+=(--onboard-to-prism-central=false)
}

redacted_command() {
  local a out=()
  for a in "${CMD[@]}"; do
    case $a in
      --registry-password=*) out+=("--registry-password=********") ;;
      --nutanix-registry-password=*) out+=("--nutanix-registry-password=********") ;;
      --registry-mirror-password=*) out+=("--registry-mirror-password=********") ;;
      --additional-trust-bundle=*) ((${#a} > 200)) && out+=("--additional-trust-bundle=<base64 Prism Central certificate>") || out+=("$a") ;;
      *) out+=("$a") ;;
    esac
  done
  printf '%q ' "${out[@]}" | sed -E 's/ --/ \\\n  --/g'
  echo
}

row() { printf '    %-26s %s\n' "$1" "$2" >&2; }

show_summary() {
  step "Summary"
  local hub=none proxy=none
  if [[ $USE_DOCKERHUB == Y ]]; then hub=$DOCKERHUB_USERNAME; fi
  if [[ $USE_PROXY == Y ]]; then proxy=$PROXY_HTTPS; fi
  row "Cluster name" "$CLUSTER_NAME"
  if ((WORKLOAD)); then
    row "Management cluster" "$MGMT_CLUSTER_NAME ($MGMT_KCFG)"
    row "Workspace namespace" "$WORKSPACE_NAMESPACE"
  fi
  row "Prism Central" "$NUTANIX_ENDPOINT (user ${NUTANIX_USER}, TLS: ${TLS_MODE})"
  row "Prism Element" "$NUTANIX_CLUSTER"
  row "Subnet" "$SUBNET${NODE_CIDR:+ ($NODE_CIDR)}${NODE_POOLS:+, IPAM pool $NODE_POOLS}"
  if [[ -n $(ip_plan_get IP_PLAN_BLOCK) ]]; then
    row "Reserved for NKP" "$(ip_plan_get IP_PLAN_BLOCK) (${WORKDIR}/nkp-ip-plan.env)"
    if [[ -n $(ip_plan_get IP_PLAN_DNS) ]]; then row "DHCP DNS / domain" "$(ip_plan_get IP_PLAN_DNS) / $(ip_plan_get IP_PLAN_DOMAIN)"; fi
  fi
  row "Node image" "$VM_IMAGE"
  row "Storage container" "$STORAGE_CONTAINER_NAME"
  row "Control plane endpoint" "$CONTROLPLANE_IP"
  row "Load balancer range" "$SERVICE_LB_IP_RANGE (NKP UI: $(ipcalc range_first "$SERVICE_LB_IP_RANGE"))"
  row "Pod / service CIDR" "$POD_CIDR / $SERVICE_CIDR"
  row "Sizing" "$SIZING"
  row "SSH" "$SSH_USERNAME, key $SSH_PUBLIC_KEY"
  if ((${#BUNDLE_ARGS[@]})); then
    row "Images" "bundle (${BUNDLE_COUNT} files from ${BUNDLE_DIR}) -> internal registry mirror"
    row "Then" "${REGISTRY_MIRROR_URL:-Harbor on ${CLUSTER_NAME}}: push the bundle for workload clusters"
  elif ((${#REGISTRY_MIRROR_ARGS[@]})); then
    row "Images" "Harbor ${NCR_URL} (${NCR_AUTH})"
  else
    row "Images" "internet (Docker Hub)"
  fi
  row "Docker Hub credentials" "$hub"
  if ((${#NUTANIX_REGISTRY_ARGS[@]})); then row "Nutanix registry user" "$NUTANIX_REGISTRY_USERNAME"; fi
  row "Proxy" "$proxy"
  row "NTP servers" "${NTP_SERVERS:-image defaults}"
  row "Prism Central onboarding" "$ONBOARD_PC"
  row "Working directory" "$CLUSTER_DIR"
  redacted_command >"${CLUSTER_DIR}/create-cluster.cmd"
  echo >&2
  sed 's/^/    /' "${CLUSTER_DIR}/create-cluster.cmd" >&2
}

run_preflight() {
  ask_yn "Run the NKP preflight checks now (dry run, nothing is created)?" Y || return 0
  local yaml="${CLUSTER_DIR}/cluster-dryrun.yaml" log="${CLUSTER_DIR}/preflight.log"
  if (cd "$CLUSTER_DIR" && umask 077 && "${CMD[@]}" --dry-run --output=yaml >"$yaml" 2> >(tee "$log" >&2)); then
    ok "Preflight checks passed. Generated manifests: ${yaml} (contains credentials; mode 600)"
  else
    err "Preflight checks failed; see above or ${log}."
    local rerun="${SCRIPT_PATH} --skip-prereqs"
    if ((WORKLOAD)); then rerun="${SCRIPT_PATH} --workload"; fi
    ask_yn "Continue to cluster creation anyway?" N || { info "Answers saved; fix them by rerunning: ${rerun}"; exit 1; }
  fi
}

run_create() {
  if ((PRINT_ONLY)); then
    info "--print-only: not creating the cluster. Command saved to ${CLUSTER_DIR}/create-cluster.cmd"
    exit 0
  fi
  local kind=management rerun="${SCRIPT_PATH} --skip-prereqs"
  if ((WORKLOAD)); then kind=workload rerun="${SCRIPT_PATH} --workload"; fi
  ask_yn "Create the ${kind} cluster now?" Y || { info "Answers saved; rerun with: ${rerun}"; exit 0; }
  LOG="${CLUSTER_DIR}/create-cluster-$(date +%Y%m%d-%H%M%S).log"
  step "Creating ${CLUSTER_NAME} (log: ${LOG})"
  if ! (cd "$CLUSTER_DIR" && "${CMD[@]}") 2>&1 | tee -a "$LOG"; then
    err "Cluster creation failed. Full log: ${LOG}"
    if ((WORKLOAD)); then
      if "${MGMT_K[@]}" -n "$WORKSPACE_NAMESPACE" get clusters.cluster.x-k8s.io "$CLUSTER_NAME" >/dev/null 2>&1; then
        warn "${CLUSTER_NAME} exists on ${MGMT_CLUSTER_NAME} and keeps reconciling; do not create it again."
        nkp describe cluster -c "$CLUSTER_NAME" -n "$WORKSPACE_NAMESPACE" --kubeconfig="$MGMT_KCFG" >&2 || true
        info "Follow it with: nkp describe cluster -c ${CLUSTER_NAME} -n ${WORKSPACE_NAMESPACE} --kubeconfig=${MGMT_KCFG}"
      else
        info "Nothing was created. Fix the cause, then rerun: ${rerun}"
      fi
    elif [[ -f ${CLUSTER_DIR}/${CLUSTER_NAME}.conf ]]; then
      warn "The cluster itself exists (its VMs are running); only the steps after it failed."
      warn "Do not rerun the setup: it would try to create ${CLUSTER_NAME} again."
      cluster_status "${CLUSTER_DIR}/${CLUSTER_NAME}.conf"
      if [[ -n $(kubectl --kubeconfig "${CLUSTER_DIR}/${CLUSTER_NAME}.conf" -n kommander get helmreleases --no-headers 2>/dev/null || true) ]]; then
        info "Platform apps keep retrying on their own. Check again with: ${SCRIPT_PATH} --status"
      else
        info "Kommander stopped before deploying any platform app; it does not resume by itself."
        info "Fix the cause (often nodes too small: see 'kubectl top nodes'), then either retry Kommander per the NKP guide"
        info "(nkp install kommander --kubeconfig ... --kommander-applications-repository <bundle>/application-repositories/...)"
        info "or start over: ${SCRIPT_PATH} --destroy, then rerun the setup."
      fi
    else
      info "If a local bootstrap cluster was left behind, remove it with: nkp delete bootstrap"
      info "Fix the cause, then rerun: ${SCRIPT_PATH} --skip-prereqs"
    fi
    exit 1
  fi
}

cluster_status() { # kubeconfig
  local k=(kubectl --kubeconfig "$1") out
  step "Cluster status (${1})"
  "${k[@]}" get nodes -o wide >&2 || { warn "The cluster API is not reachable with this kubeconfig."; return 0; }
  out=$("${k[@]}" -n kommander get helmreleases --no-headers 2>/dev/null || true)
  if [[ -z $out ]]; then
    warn "No platform applications (HelmReleases in kommander): Kommander did not get past its own installation."
    "${k[@]}" get gitclaims.git.nutanix.com -A >&2 2>/dev/null || true
  elif ! awk '$0 !~ /True/ {exit 1}' <<<"$out"; then
    info "Platform applications not ready:"; awk '$0 !~ /True/' <<<"$out" >&2
  else ok "All platform applications are ready"; fi
  out=$("${k[@]}" get pods -A 2>&1 | awk 'NR == 1 || ($4 != "Running" && $4 != "Completed") || $3 ~ /^0\//' || true)
  if [[ $(wc -l <<<"$out") -gt 1 ]]; then
    info "Pods not running or not ready:"; printf '%s\n' "$out" >&2
    if [[ $out == *Pending* ]]; then
      info "Pending pods with 'Insufficient cpu/memory' events below need more workers. List and scale the pool with:"
      info "  nkp get nodepools --cluster-name=${CLUSTER_NAME} -n kommander --kubeconfig=${1}"
      info "  nkp scale nodepools md-0 --replicas=<n> --cluster-name=${CLUSTER_NAME} -n kommander --kubeconfig=${1}"
    fi
  fi
  info "Load balancer services (the ingress needs an EXTERNAL-IP from the service IP range):"
  "${k[@]}" get svc -A 2>&1 | awk 'NR == 1 || /LoadBalancer/' >&2 || true
  info "Recent warning events:"
  "${k[@]}" get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -15 >&2 || true
  info "Node usage:"
  "${k[@]}" top nodes >&2 2>/dev/null || info "(metrics not available yet)"
}

phase_status() {
  local kcfg
  ANSWERS_FILE="${WORKDIR}/nkp-install.env"
  if [[ -f $ANSWERS_FILE ]]; then
    # shellcheck disable=SC1090
    . "$ANSWERS_FILE"
  fi
  CLUSTER_NAME=${CLUSTER_NAME:-nkp-mgmt}
  kcfg="${WORKDIR}/${CLUSTER_NAME}/${CLUSTER_NAME}.conf"
  [[ -f $kcfg ]] || die "No kubeconfig at ${kcfg}. Has the cluster been created? (use --workdir if it lives elsewhere)"
  cluster_status "$kcfg"
  info "Clusters in NKP workspaces (workload clusters show Joined once attached):"
  kubectl --kubeconfig "$kcfg" get nkpclusters -A >&2 2>/dev/null || true
  nkp get dashboard --kubeconfig="$kcfg" 2>/dev/null || true
  local url
  url=$(harbor_marker_get "$CLUSTER_NAME" HARBOR_URL)
  if [[ -n $url ]]; then
    info "Harbor for workload clusters: ${url} (bundles pushed $(harbor_marker_get "$CLUSTER_NAME" PUSH_DATE))"
    if [[ $(harbor_marker_get "$CLUSTER_NAME" HARBOR_EXTERNAL) != Y ]]; then info "  admin password: $(harbor_password_cmd "$kcfg")"; fi
  elif [[ ${USE_BUNDLE:-N} == Y ]]; then
    info "No bundle pushed to Harbor yet; workload clusters pull from the internet. Push it: ${SCRIPT_PATH} --harbor"
  fi
  if write_lab_summary; then info "Lab summary: ${WORKDIR}/lab-summary.txt"; fi
}

write_lab_summary() { # -> ${WORKDIR}/lab-summary.txt, mode 600 (it holds the dashboard password)
  local f="${WORKDIR}/lab-summary.txt" mask
  [[ -f ${WORKDIR}/nkp-install.env ]] || return 1
  mask=$(umask)
  umask 077
  (
    # shellcheck disable=SC1090,SC1091
    . "${WORKDIR}/nkp-install.env"
    m=$CLUSTER_NAME mk="${WORKDIR}/${CLUSTER_NAME}/${CLUSTER_NAME}.conf" url=""
    printf 'NKP %s lab, summary written %s\n\n' "$NKP_MINOR" "$(date '+%F %T')"
    printf '%-22s %s (user %s)\n' "Prism Central" "$NUTANIX_ENDPOINT" "$NUTANIX_USER"
    printf '%-22s %s\n' "Prism Element" "$NUTANIX_CLUSTER" "Subnet" "${SUBNET}${NODE_CIDR:+ (${NODE_CIDR})}"
    if [[ -n $(ip_plan_get IP_PLAN_BLOCK) ]]; then
      printf '%-22s %s\n' "Reserved for NKP" "$(ip_plan_get IP_PLAN_BLOCK) (IPAM pool now: $(ip_plan_get IP_PLAN_NEW_POOLS))"
      if [[ -n $(ip_plan_get IP_PLAN_DNS) ]]; then
        printf '%-22s %s\n' "DHCP DNS / domain" "$(ip_plan_get IP_PLAN_DNS) (${LAB_DNS_VM}) / $(ip_plan_get IP_PLAN_DOMAIN)"
      fi
    fi
    printf '\nManagement cluster     %s\n' "$m"
    printf '  %-20s %s\n' "API endpoint" "https://${CONTROLPLANE_IP}:6443" "Load balancer range" "$SERVICE_LB_IP_RANGE" "Kubeconfig" "$mk"
    if [[ -f $mk ]]; then
      printf '  Dashboard\n'
      nkp get dashboard --kubeconfig="$mk" 2>/dev/null | sed 's/^/    /' || echo "    (not available yet: nkp get dashboard --kubeconfig=${mk})"
    fi
    url=$(harbor_marker_get "$m" HARBOR_URL)
    if [[ -n $url ]]; then
      printf '  %-20s %s\n' "Harbor" "${url} (bundles pushed $(harbor_marker_get "$m" PUSH_DATE))"
      if [[ $(harbor_marker_get "$m" HARBOR_EXTERNAL) == Y ]]; then
        printf '    user: %s (REGISTRY_MIRROR_URL)\n' "$(harbor_marker_get "$m" HARBOR_USER)"
      else
        printf '    user admin, password: %s\n' "$(harbor_password_cmd "$mk")"
      fi
    elif [[ ${USE_BUNDLE:-} == Y ]]; then
      printf '  %-20s %s\n' "Harbor" "bundle not pushed yet: ${SCRIPT_PATH} --harbor"
    fi
    if [[ -f ${WORKDIR}/nkp-workload.env ]]; then
      # shellcheck disable=SC1090,SC1091
      . "${WORKDIR}/nkp-workload.env"
      printf '\nWorkload cluster       %s (workspace %s)\n' "$CLUSTER_NAME" "$WORKSPACE_NAMESPACE"
      printf '  %-20s %s\n' "API endpoint" "https://${CONTROLPLANE_IP}:6443" "Load balancer range" "$SERVICE_LB_IP_RANGE" \
        "Kubeconfig" "${WORKDIR}/${CLUSTER_NAME}/${CLUSTER_NAME}.conf"
      if [[ ${USE_MGMT_REGISTRY:-} == Y ]]; then
        printf '  %-20s %s\n' "Images" "from Harbor${url:+ ${url}}"
      fi
      if [[ -f $mk ]]; then
        printf '  %-20s %s\n' "State" "$(kubectl --kubeconfig "$mk" -n "$WORKSPACE_NAMESPACE" get nkpclusters "$CLUSTER_NAME" --no-headers 2>/dev/null || echo unknown)"
      fi
    fi
    cat <<EOF

Commands
  export KUBECONFIG=${mk}
  kubectl get nkpclusters -A
  nkp get dashboard
  nkp get nodepools -c ${m} -n kommander

  Status:                ${SCRIPT_PATH} --status
  Another workload:      ${SCRIPT_PATH} --workload
  Push the bundle:       ${SCRIPT_PATH} --harbor
  Delete the whole lab:  ${SCRIPT_PATH} --destroy
EOF
  ) >"$f.tmp" 2>/dev/null || true
  umask "$mask"
  mv -f "$f.tmp" "$f"
  chmod 600 "$f"
}

helmreleases_not_ready() { # kubeconfig namespace -> "name<TAB>message" of HelmReleases not Ready; exit 1 if none exist yet
  py k8s hr-not-ready "$2" --kubeconfig "$1" 2>/dev/null
}

wait_helmreleases() { # kubeconfig namespace minutes -> 0 once every HelmRelease is Ready
  local i out
  for ((i = 0; i < $3 * 6; i++)); do
    if out=$(helmreleases_not_ready "$1" "$2") && [[ -z $out ]]; then return 0; fi
    sleep 10
  done
  return 1
}

remediate_apps() { # kubeconfig cluster hr_namespace management_kubeconfig: add workers for unschedulable pods, retry failed apps
  local kcfg=$1 cluster=$2 hr_ns=$3 mgmt=$4 attempt starved md md_ns md_name replicas failed
  for attempt in 1 2; do
    starved=$(py k8s starved-pods --kubeconfig "$kcfg" 2>/dev/null || true)
    if [[ -n $starved ]]; then
      warn "Pods that cannot be scheduled for lack of CPU or memory: ${starved//$'\n'/ }"
      md=$(py k8s md0 "$cluster" --kubeconfig "$mgmt" 2>/dev/null || true)
      read -r md_ns md_name replicas <<<"$md"
      if [[ ! ${replicas:-} =~ ^[0-9]+$ ]]; then warn "Could not find node pool md-0 of ${cluster}; scale it yourself."; break; fi
      ask_yn "Add a worker to ${cluster} (md-0: ${replicas} -> $((replicas + 1)), attempt ${attempt} of 2)?" Y || break
      if ! nkp scale nodepools md-0 --replicas="$((replicas + 1))" -c "$cluster" -n "$md_ns" --kubeconfig="$mgmt" >&2; then
        warn "Scaling md-0 failed."; break
      fi
      info "Waiting for the new worker (up to 20 minutes)..."
      kubectl --kubeconfig "$mgmt" -n "$md_ns" wait --for=jsonpath='{.status.readyReplicas}'="$((replicas + 1))" \
        "machinedeployments.cluster.x-k8s.io/${md_name}" --timeout=20m >&2 || warn "The new worker is not ready yet."
    fi
    failed=$(helmreleases_not_ready "$kcfg" "$hr_ns" | cut -f1 || true)
    # shellcheck disable=SC2086  # one argument per HelmRelease name
    if [[ -n $failed ]]; then py k8s hr-reconcile "$hr_ns" $failed --kubeconfig "$kcfg" >/dev/null 2>&1 || true; fi
    info "Retrying ${failed//$'\n'/ }; waiting up to 20 more minutes..."
    if wait_helmreleases "$kcfg" "$hr_ns" 20; then ok "All platform applications are ready"; return 0; fi
    [[ -n $starved ]] || break
  done
  return 1
}

post_install() {
  local kcfg="${CLUSTER_DIR}/${CLUSTER_NAME}.conf"
  step "Verifying the installation"
  if [[ ! -f $kcfg ]]; then
    warn "Expected kubeconfig ${kcfg} was not found. Check the log for where nkp wrote it."
    return
  fi
  chmod 600 "$kcfg"
  ok "Kubeconfig: ${kcfg}"
  kubectl --kubeconfig "$kcfg" get nodes -o wide || true
  info "Waiting for the NKP platform applications (up to 30 minutes)..."
  if wait_helmreleases "$kcfg" kommander 30; then
    ok "All platform applications are ready"
  else
    warn "Platform applications not ready after 30 minutes:"
    helmreleases_not_ready "$kcfg" kommander | sed 's/^/      /' >&2 || true
    remediate_apps "$kcfg" "$CLUSTER_NAME" kommander "$kcfg" \
      || warn "Some applications are still not ready. Check: ${SCRIPT_PATH} --status"
  fi
  step "NKP dashboard"
  nkp get dashboard --kubeconfig="$kcfg" || true
  cat >&2 <<EOF

    Next steps:
      export KUBECONFIG=${kcfg}
      nkp rotate dashboard-credentials        # then: nkp get dashboard
      Dashboard > Global > Settings > Licensing > Activate License   (key from the Nutanix Portal)
      Node pool commands on this cluster need: -n kommander
      Workload clusters: ${SCRIPT_PATH} --workload
EOF
  if [[ ${USE_BUNDLE:-N} == Y || -n ${REGISTRY_MIRROR_URL:-} ]]; then
    harbor_step "$CLUSTER_NAME" "$kcfg" || warn "Workload clusters pull from the internet until the images are pushed: ${SCRIPT_PATH} --harbor"
  fi
  if ((!LAB)) && ask_yn "Create a workload cluster on ${CLUSTER_NAME} now?" N; then
    local args=(--workload --workdir "$WORKDIR")
    if ((FORCE_INSECURE)); then args+=(--insecure); fi
    exec bash "$SCRIPT_PATH" "${args[@]}"
  fi
}

phase_setup() {
  step "Phase 2: interactive cluster setup"
  command -v nkp >/dev/null || die "nkp CLI not found. Run without --skip-prereqs first."
  ensure_docker_access
  ensure_tmux_session
  PC_API_OK=0 TLS_MODE="" TRUST_ARGS=() NUTANIX_REGISTRY_ARGS=() NODE_CIDR="" NODE_POOLS=""
  BUNDLE_ARGS=() BUNDLE_FILES="" REGISTRY_MIRROR_ARGS=() NCR_URL="" NCR_AUTH=""
  load_answers
  q_cluster
  q_prism_central
  q_inventory
  lab_network
  q_network
  q_sizing
  q_bundle
  q_access
  q_extras
  save_answers
  ok "Answers saved to ${ANSWERS_FILE} (no passwords)"
  # shellcheck disable=SC2046
  capacity_check $(sizing_need)
  build_command
  show_summary
  export NUTANIX_USER NUTANIX_PASSWORD
  run_preflight
  run_create
  post_install
}

v_lab_workload_name() {
  v_cluster_name "$1" || return 1
  if [[ $1 == "$MGMT_CLUSTER_NAME" ]]; then echo "      That is the management cluster's name." >&2; return 1; fi
}

q_lab_workload() { # workload answers asked up front, checked offline: the management cluster does not exist yet
  step "First workload cluster"
  local mgmt_ranges="${CONTROLPLANE_IP}-${CONTROLPLANE_IP},${SERVICE_LB_IP_RANGE}" mgmt_args=("${SIZING_ARGS[@]}") saved=$ANSWERS_FILE
  MGMT_CLUSTER_NAME=$CLUSTER_NAME
  swap_wl
  CLUSTER_NAME=${CLUSTER_NAME:-nkp-workload1}
  ask CLUSTER_NAME "Workload cluster name" v_lab_workload_name
  WORKSPACE_NAMESPACE=${WORKSPACE_NAMESPACE:-kommander-default-workspace}
  ask WORKSPACE_NAMESPACE "Workspace namespace for it (created if missing)" v_dns_label
  RESERVED_RANGES=$mgmt_ranges
  q_network ips-only
  RESERVED_RANGES=""
  SIZING=${SIZING:-$WL_SIZING}
  q_sizing workload
  WL_NEED=$(sizing_need)
  ANSWERS_FILE="${WORKDIR}/nkp-workload.env"
  save_answers
  ANSWERS_FILE=$saved
  swap_wl
  SIZING_ARGS=("${mgmt_args[@]}")
  ok "Workload answers saved to ${WORKDIR}/nkp-workload.env"
}

phase_lab() {
  step "NKP ${NKP_MINOR} lab: management cluster and first workload cluster"
  command -v nkp >/dev/null || die "nkp CLI not found. Run without --skip-prereqs first."
  ensure_docker_access
  ensure_tmux_session
  PC_API_OK=0 TLS_MODE="" TRUST_ARGS=() NUTANIX_REGISTRY_ARGS=() NODE_CIDR="" NODE_POOLS=""
  BUNDLE_ARGS=() BUNDLE_FILES="" REGISTRY_MIRROR_ARGS=() NCR_URL="" NCR_AUTH=""
  load_answers
  q_cluster
  q_prism_central
  q_inventory
  lab_network
  q_network
  q_sizing
  q_bundle
  q_access
  q_extras
  if [[ -n ${REGISTRY_MIRROR_URL:-} ]]; then
    ask_secret REGISTRY_MIRROR_PASSWORD "Password of ${REGISTRY_MIRROR_USERNAME:-admin} on ${REGISTRY_MIRROR_URL}"
  fi
  save_answers
  ok "Answers saved to ${ANSWERS_FILE} (no passwords)"
  build_command
  local mgmt_need n1 c1 m1 n2 c2 m2 args rc=0
  mgmt_need=$(sizing_need)
  q_lab_workload
  read -r n1 c1 m1 <<<"$mgmt_need"
  read -r n2 c2 m2 <<<"$WL_NEED"
  capacity_check $((n1 + n2)) $((c1 + c2)) $((m1 + m2))
  show_summary
  step "Then, from ${CLUSTER_NAME}: workload cluster ${WL_CLUSTER_NAME}"
  row "Workspace namespace" "$WL_WORKSPACE_NAMESPACE"
  row "Control plane endpoint" "$WL_CONTROLPLANE_IP"
  row "Load balancer range" "$WL_LB_RANGE"
  row "Sizing" "$WL_SIZING"
  ask_yn "Create ${CLUSTER_NAME}${BUNDLE_FILES:+, set up Harbor} and then ${WL_CLUSTER_NAME} now, without further questions (about 2 hours)?" Y \
    || { info "Answers saved; rerun with: ${SCRIPT_PATH} --lab --skip-prereqs"; exit 0; }
  UNATTENDED=1
  export NUTANIX_USER NUTANIX_PASSWORD
  run_preflight
  run_create
  post_install

  step "Creating workload cluster ${WL_CLUSTER_NAME}"
  args=(--workload --unattended --skip-prereqs --workdir "$WORKDIR")
  if ((FORCE_INSECURE)); then args+=(--insecure); fi
  if [[ -n ${DOCKERHUB_PASSWORD:-} ]]; then export DOCKERHUB_PASSWORD; fi
  if [[ -n ${REGISTRY_MIRROR_PASSWORD:-} ]]; then export REGISTRY_MIRROR_PASSWORD; fi
  NKP_LAB_CHILD=1 bash "$SCRIPT_PATH" "${args[@]}" || rc=$?
  ((rc == 0)) || warn "The workload cluster run ended with exit ${rc}. Rerun it with: ${SCRIPT_PATH} --workload"
  write_lab_summary || true
  step "Lab summary (${WORKDIR}/lab-summary.txt)"
  sed 's/^/    /' "${WORKDIR}/lab-summary.txt" >&2 || true
}

# ---------------------------------------------------------------------------
# Workload (managed) clusters
# ---------------------------------------------------------------------------

load_mgmt_context() {
  local f="${WORKDIR}/nkp-install.env" kv
  [[ -f $f ]] || die "No management cluster answers at ${f}. Create the management cluster first, or pass --workdir."
  # shellcheck disable=SC1090
  . "$f"
  MGMT_CLUSTER_NAME=$CLUSTER_NAME MGMT_USE_BUNDLE=${USE_BUNDLE:-N}
  MGMT_KCFG="${WORKDIR}/${MGMT_CLUSTER_NAME}/${MGMT_CLUSTER_NAME}.conf"
  [[ -f $MGMT_KCFG ]] || die "No kubeconfig for ${MGMT_CLUSTER_NAME} at ${MGMT_KCFG}."
  MGMT_K=(kubectl --kubeconfig "$MGMT_KCFG")
  RESERVED_RANGES=$(py k8s reserved-ranges --kubeconfig "$MGMT_KCFG" 2>/dev/null) \
    || die "Cannot list Cluster API clusters on ${MGMT_CLUSTER_NAME} with ${MGMT_KCFG}. Is it up? Try: ${SCRIPT_PATH} --status"
  ok "Management cluster ${MGMT_CLUSTER_NAME} is reachable"
  kv=$(py k8s kubelet-version --kubeconfig "$MGMT_KCFG" 2>/dev/null || true)
  if [[ $kv =~ ^v?([0-9]+\.[0-9]+) ]]; then
    K8S_VERSION_HINT=${BASH_REMATCH[1]}
    info "${MGMT_CLUSTER_NAME} runs Kubernetes ${kv}; the workload node image should be built for ${K8S_VERSION_HINT}."
  fi
  if [[ -n ${CONTROLPLANE_IP:-} ]]; then RESERVED_RANGES+="${RESERVED_RANGES:+,}${CONTROLPLANE_IP}-${CONTROLPLANE_IP}"; fi
  if [[ -n ${SERVICE_LB_IP_RANGE:-} ]]; then RESERVED_RANGES+="${RESERVED_RANGES:+,}${SERVICE_LB_IP_RANGE}"; fi
  RESERVED_RANGES=$(tr ',' '\n' <<<"$RESERVED_RANGES" | awk 'NF && !seen[$0]++' | paste -sd, - || true)
  [[ -z $RESERVED_RANGES ]] || info "Addresses already used by NKP clusters: ${RESERVED_RANGES}"
}

# ---------------------------------------------------------------------------
# Harbor: the registry workload clusters pull from
# ---------------------------------------------------------------------------

harbor_marker() { printf '%s' "${WORKDIR}/$1/harbor-push.env"; } # management cluster -> its push record (no secrets)

harbor_marker_get() { # management cluster, KEY -> its value in the push record
  local f; f=$(harbor_marker "$1")
  [[ -f $f ]] || return 0
  # shellcheck disable=SC1090
  (. "$f"; printf '%s' "${!2:-}")
}

hpy() { # nkp_lab.py harbor ... against HARBOR_URL as HARBOR_USER (password through the environment)
  NKP_HARBOR_URL="$HARBOR_URL" NKP_HARBOR_CA="${HARBOR_CACERT:-}" NKP_HARBOR_USER="${HARBOR_USER:-admin}" \
    NKP_HARBOR_PASSWORD="${HARBOR_PASSWORD:-}" py harbor "$@"
}

harbor_project() { # https://host[:port]/project[/...] -> project
  local p=${1#*://}
  [[ $p == */* ]] || return 0
  p=${p#*/}
  printf '%s' "${p%%/*}"
}

harbor_password_cmd() { # management kubeconfig -> the command that prints the Harbor admin password
  printf "kubectl --kubeconfig %s -n ncr-system get secret harbor-admin-password -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d" "$1"
}

harbor_login() { # management cluster, kubeconfig -> HARBOR_URL HARBOR_CACERT HARBOR_USER HARBOR_PASSWORD HARBOR_EXTERNAL
  if [[ -n ${REGISTRY_MIRROR_URL:-} ]]; then
    HARBOR_EXTERNAL=Y HARBOR_URL=${REGISTRY_MIRROR_URL%/} HARBOR_CACERT=${REGISTRY_MIRROR_CACERT:-}
    HARBOR_USER=${REGISTRY_MIRROR_USERNAME:-admin}
    ask_secret REGISTRY_MIRROR_PASSWORD "Password of ${HARBOR_USER} on ${HARBOR_URL}"
    HARBOR_PASSWORD=$REGISTRY_MIRROR_PASSWORD
    return 0
  fi
  HARBOR_EXTERNAL=N HARBOR_USER=admin
  HARBOR_URL=$(harbor_marker_get "$1" HARBOR_URL) HARBOR_CACERT=$(harbor_marker_get "$1" HARBOR_CACERT)
  HARBOR_PASSWORD=$(py k8s harbor-password --kubeconfig "$2" 2>/dev/null) \
    || die "Cannot read the Harbor admin password from $1 (ncr-system/harbor-admin-password)."
}

harbor_step() { # management cluster, kubeconfig: Harbor on it (or REGISTRY_MIRROR_URL), the bundle pushed into project nkp
  local mgmt=$1 kcfg=$2 marker files dir parts f push=() shown=() proj uid repos k
  local NCR_HOST="" NCR_PRESENT=N NCR_CA_FOUND=N PUSH_UID PUSH_BUNDLES PUSH_DATE
  marker=$(harbor_marker "$mgmt")
  step "Harbor: the registry for workload clusters"
  files=${BUNDLE_FILES:-}
  if [[ -z $files ]]; then
    dir=${BUNDLE_DIR_ARG:-${BUNDLE_DIR:-}}
    [[ -n $dir && -d $dir ]] || dir=$(bundle_candidates | awk 'NR == 1')
    if [[ -z $dir ]]; then
      warn "No extracted nkp-v${NKP_MINOR}.x/container-images under ${HOME}/nkp-dist or ${HOME}; nothing to push. Use --bundle-dir DIR."
      return 1
    fi
    files=$(bundle_files "$dir") || return 1
  fi

  if [[ -n ${REGISTRY_MIRROR_URL:-} ]]; then
    harbor_login "$mgmt" "$kcfg"
    info "Registry: REGISTRY_MIRROR_URL ${HARBOR_URL}; no Harbor is deployed on ${mgmt}."
  else
    HARBOR_CACERT="${WORKDIR}/${mgmt}/harbor-ca.pem"
    py_vars k8s ncr --kubeconfig "$kcfg" --ca-out "$HARBOR_CACERT" \
      || die "Cannot read the ingress of ${mgmt} (kommandercluster). Try: ${SCRIPT_PATH} --status"
    [[ -n $NCR_HOST ]] || die "${mgmt} has no ingress address yet. Try: ${SCRIPT_PATH} --status"
    if [[ $NCR_PRESENT == Y ]]; then
      ok "Harbor is already running on ${mgmt} (namespace ncr-system)"
    else
      info "Enables CloudNativePG, raises Rook Ceph to ${CEPH_OSD_COUNT} volumes of 40 GiB, creates an object bucket and enables"
      info "Harbor (namespace ncr-system), as in the NKP ${NKP_MINOR} guide 'Deploying Harbor on a Management Cluster'."
      if [[ -n $HARBOR_OVERRIDES_FILE ]]; then info "Harbor values: ${HARBOR_OVERRIDES_FILE}"; fi
      ask_yn "Deploy Harbor on ${mgmt} now (about 15 minutes)?" Y || { info "Skipped. Later: ${SCRIPT_PATH} --harbor"; return 1; }
      py k8s harbor-deploy --kubeconfig "$kcfg" --ceph-count "$CEPH_OSD_COUNT" \
        ${HARBOR_OVERRIDES_FILE:+--overrides-file "$HARBOR_OVERRIDES_FILE"} >/dev/null \
        || die "Harbor did not come up. Check: kubectl --kubeconfig ${kcfg} -n ncr-system get helmreleases,pods"
      py_vars k8s ncr --kubeconfig "$kcfg" --ca-out "$HARBOR_CACERT" || true
      ok "Harbor is running on ${mgmt}"
    fi
    [[ $NCR_CA_FOUND == Y ]] || die "Cannot read the ingress CA of ${mgmt} (kommandercluster status.ingress.caBundle)."
    HARBOR_URL="https://${NCR_HOST}:${NCR_PORT}/${HARBOR_PROJECT}" HARBOR_EXTERNAL=N HARBOR_USER=admin
    HARBOR_PASSWORD=$(py k8s harbor-password --kubeconfig "$kcfg") \
      || die "Cannot read the Harbor admin password from ${mgmt} (ncr-system/harbor-admin-password)."
  fi
  hpy ping || die "Harbor at ${HARBOR_URL} does not answer from this host${HARBOR_CACERT:+ with the CA ${HARBOR_CACERT}}."
  ok "Harbor answers at ${HARBOR_URL}"
  proj=$(harbor_project "$HARBOR_URL")
  [[ -n $proj ]] || die "The registry URL ${HARBOR_URL} has no Harbor project; use https://<host>/<project>, e.g. .../${HARBOR_PROJECT}."
  hpy ensure-project "$proj" || die "Cannot create the Harbor project ${proj}."

  PUSH_UID=$(py k8s uid --kubeconfig "$kcfg" 2>/dev/null || echo unknown) PUSH_BUNDLES=$files PUSH_DATE=$(date -Is)
  if [[ $(harbor_marker_get "$mgmt" PUSH_UID) == "$PUSH_UID" && $(harbor_marker_get "$mgmt" HARBOR_URL) == "$HARBOR_URL" \
        && $(harbor_marker_get "$mgmt" PUSH_BUNDLES) == "$files" ]]; then
    ok "These bundles were pushed to ${HARBOR_URL} on $(harbor_marker_get "$mgmt" PUSH_DATE); not pushing again."
    return 0
  fi
  IFS=, read -r -a parts <<<"$files"
  repos=$(hpy repos "$proj" 2>/dev/null || echo 0)
  if [[ $repos =~ ^[0-9]+$ ]] && ((repos > 0)) \
     && ! ask_yn "Project ${proj} already holds ${repos} repositories. Push the ${#parts[@]} bundles anyway?" N; then
    info "Not pushing; workload clusters use what is already in ${HARBOR_URL}."
    PUSH_BUNDLES="existing (${repos} repositories)"
  else
    push=(nkp push bundle)
    for f in "${parts[@]}"; do push+=(--bundle "$f"); done
    push+=(--to-registry="$HARBOR_URL" --to-registry-username="$HARBOR_USER")
    shown=("${push[@]}" --to-registry-password=********)
    push+=(--to-registry-password="$HARBOR_PASSWORD")
    if [[ -n $HARBOR_CACERT ]]; then push+=(--to-registry-ca-cert-file="$HARBOR_CACERT") shown+=(--to-registry-ca-cert-file="$HARBOR_CACERT"); fi
    info "Pushing ${#parts[@]} bundles to ${HARBOR_URL}; this takes 30-90 minutes:"
    printf '%q ' "${shown[@]}" | sed -E 's/ --/ \\\n      --/g; s/^/      /' >&2
    echo >&2
    "${push[@]}" >&2 || die "nkp push bundle failed. Rerun: ${SCRIPT_PATH} --harbor"
    ok "Bundles pushed to ${HARBOR_URL}"
  fi
  (
    umask 077
    echo "# Images for workload clusters of ${mgmt}, written $(date -Is). No secrets."
    for k in HARBOR_URL HARBOR_CACERT HARBOR_EXTERNAL HARBOR_USER PUSH_UID PUSH_BUNDLES PUSH_DATE; do
      printf '%s=%q\n' "$k" "${!k}"
    done
  ) >"$marker"
  chmod 600 "$marker"
}

phase_harbor() { # --harbor: deploy Harbor and push the bundle for the management cluster this script created
  step "Harbor"
  command -v nkp >/dev/null || die "nkp CLI not found. Run the setup first."
  ensure_docker_access
  ensure_tmux_session
  BUNDLE_FILES=""
  load_mgmt_context
  harbor_step "$MGMT_CLUSTER_NAME" "$MGMT_KCFG" || exit 1
  write_lab_summary || true
  info "Workload clusters now pull from ${HARBOR_URL}: ${SCRIPT_PATH} --workload"
}

q_mgmt_registry() { # workload cluster: pull its images from the Harbor the bundle was pushed to
  REGISTRY_MIRROR_ARGS=() NCR_URL="" NCR_AUTH=""
  local marker def=${USE_MGMT_REGISTRY:-Y} proj robot user="" pass=""
  marker=$(harbor_marker "$MGMT_CLUSTER_NAME")
  step "Images"
  if [[ $(nkp create cluster nutanix --help 2>&1 || true) != *--registry-mirror-url* ]]; then
    warn "This nkp CLI has no --registry-mirror-url option; ${CLUSTER_NAME} pulls from the internet."
    USE_MGMT_REGISTRY=N
    return 0
  fi
  if [[ ! -f $marker && $def != N ]]; then
    info "No bundle has been pushed to a registry for ${MGMT_CLUSTER_NAME} yet (${marker})."
    if [[ $MGMT_USE_BUNDLE == Y || -n ${REGISTRY_MIRROR_URL:-} ]] \
       && ask_yn "Run the Harbor step now (deploy Harbor on ${MGMT_CLUSTER_NAME} if needed, push the bundle)?" Y; then
      harbor_step "$MGMT_CLUSTER_NAME" "$MGMT_KCFG" || true
    fi
  fi
  if [[ ! -f $marker ]]; then
    info "${CLUSTER_NAME} pulls its images from the internet. To change that: ${SCRIPT_PATH} --harbor"
    USE_MGMT_REGISTRY=N
    return 0
  fi
  [[ $def == N ]] || def=Y
  HARBOR_URL=$(harbor_marker_get "$MGMT_CLUSTER_NAME" HARBOR_URL)
  if ! ask_yn "Pull ${CLUSTER_NAME}'s images from ${HARBOR_URL} instead of the internet?" "$def"; then
    USE_MGMT_REGISTRY=N
    return 0
  fi
  USE_MGMT_REGISTRY=Y
  if [[ $(harbor_marker_get "$MGMT_CLUSTER_NAME" HARBOR_EXTERNAL) == Y && -z ${REGISTRY_MIRROR_URL:-} ]]; then
    REGISTRY_MIRROR_URL=$HARBOR_URL REGISTRY_MIRROR_USERNAME=${REGISTRY_MIRROR_USERNAME:-$(harbor_marker_get "$MGMT_CLUSTER_NAME" HARBOR_USER)}
    REGISTRY_MIRROR_CACERT=${REGISTRY_MIRROR_CACERT:-$(harbor_marker_get "$MGMT_CLUSTER_NAME" HARBOR_CACERT)}
  fi
  harbor_login "$MGMT_CLUSTER_NAME" "$MGMT_KCFG"
  NCR_URL=$HARBOR_URL NCR_CACERT=$HARBOR_CACERT
  if hpy ping 2>/dev/null; then
    ok "${HARBOR_URL} answers${HARBOR_CACERT:+ and its certificate matches ${HARBOR_CACERT}}"
  else
    warn "${HARBOR_URL} does not answer from this host; the nodes may still reach it."
  fi
  proj=$(harbor_project "$HARBOR_URL")
  if [[ -n $proj ]] && hpy public "$proj" 2>/dev/null; then
    NCR_AUTH=anonymous
    ok "Project ${proj} is public; ${CLUSTER_NAME} pulls without credentials."
  elif [[ -n $proj ]] && robot=$(hpy robot "nkp-${CLUSTER_NAME#nkp-}" --project "$proj" \
         --description "Pull-only access for NKP workload cluster ${CLUSTER_NAME}" 2>/dev/null); then
    IFS=$'\t' read -r user pass <<<"$robot"
    NCR_AUTH="robot ${user}"
    ok "Created pull-only robot account ${user} on project ${proj} for ${CLUSTER_NAME}"
  else
    warn "Could not create a robot account in ${HARBOR_URL}."
    if ! ask_yn "Let ${CLUSTER_NAME} pull as ${HARBOR_USER} instead?" Y; then
      USE_MGMT_REGISTRY=N NCR_URL=""
      info "${CLUSTER_NAME} pulls its images from the internet."
      return 0
    fi
    user=$HARBOR_USER pass=$HARBOR_PASSWORD NCR_AUTH=$HARBOR_USER
  fi
  REGISTRY_MIRROR_ARGS=(--registry-mirror-url="$NCR_URL")
  if [[ -n $NCR_CACERT ]]; then REGISTRY_MIRROR_ARGS+=(--registry-mirror-cacert="$NCR_CACERT"); fi
  if [[ $NCR_AUTH != anonymous ]]; then
    REGISTRY_MIRROR_ARGS+=(--registry-mirror-username="$user" --registry-mirror-password="$pass")
  fi
}

q_workspace() {
  step "Workspace"
  info "NKP attaches the workload cluster to this workspace on ${MGMT_CLUSTER_NAME}."
  local vals=() labels=() name ns ws=""
  while IFS=$'\t' read -r name ns; do
    if [[ -n $ns ]]; then vals+=("$ns"); labels+=("${name}  (namespace ${ns})"); fi
  done < <(py k8s workspaces --kubeconfig "$MGMT_KCFG" 2>/dev/null || true)
  WORKSPACE_NAMESPACE=${WORKSPACE_NAMESPACE:-kommander-default-workspace}
  local known=0
  for ns in "${vals[@]}"; do
    if [[ $ns == "$WORKSPACE_NAMESPACE" ]]; then known=1; fi
  done
  vals+=(new); labels+=("Create a new workspace")
  if ((UNATTENDED && !known)); then
    ws=$WORKSPACE_NAMESPACE WORKSPACE_NAMESPACE=new
    v_dns_label "$ws" || die "--unattended: invalid workspace name ${ws}."
    info "Workspace ${ws} does not exist; creating it."
  else
    pick WORKSPACE_NAMESPACE "Workspace for ${CLUSTER_NAME}" vals labels
  fi
  if [[ $WORKSPACE_NAMESPACE == new ]]; then
    [[ -n $ws ]] || ask ws "New workspace name (also its namespace)" v_dns_label
    py k8s workspace-create "$ws" --kubeconfig "$MGMT_KCFG" >/dev/null || die "Could not create workspace ${ws}."
    WORKSPACE_NAMESPACE=$ws
    ok "Workspace ${ws} created"
  fi
  "${MGMT_K[@]}" get namespace "$WORKSPACE_NAMESPACE" >/dev/null 2>&1 \
    || die "Namespace ${WORKSPACE_NAMESPACE} does not exist on ${MGMT_CLUSTER_NAME}."
}

post_workload() {
  local kcfg="${CLUSTER_DIR}/${CLUSTER_NAME}.conf" i out joined=0
  local describe=(nkp describe cluster -c "$CLUSTER_NAME" -n "$WORKSPACE_NAMESPACE" --kubeconfig="$MGMT_KCFG")
  step "Waiting for ${CLUSTER_NAME}"
  info "${MGMT_CLUSTER_NAME} provisions the VMs; this usually takes 15-30 minutes. Progress: ${describe[*]}"
  if "${MGMT_K[@]}" -n "$WORKSPACE_NAMESPACE" wait --for=condition=Ready "clusters.cluster.x-k8s.io/${CLUSTER_NAME}" --timeout=60m; then
    ok "${CLUSTER_NAME} is Ready"
  else
    warn "${CLUSTER_NAME} is not Ready after 60 minutes."
    "${describe[@]}" >&2 || true
  fi
  if (umask 077 && nkp get kubeconfig -c "$CLUSTER_NAME" -n "$WORKSPACE_NAMESPACE" --kubeconfig="$MGMT_KCFG" >"$kcfg"); then
    ok "Kubeconfig: ${kcfg}"
  else
    rm -f "$kcfg"
    warn "Could not fetch the kubeconfig yet. Later: nkp get kubeconfig -c ${CLUSTER_NAME} -n ${WORKSPACE_NAMESPACE} --kubeconfig=${MGMT_KCFG} > ${kcfg}"
    return
  fi
  kubectl --kubeconfig "$kcfg" get nodes -o wide >&2 || true

  info "Waiting for ${CLUSTER_NAME} to join workspace ${WORKSPACE_NAMESPACE} (up to 20 minutes)..."
  for ((i = 0; i < 120; i++)); do
    out=$("${MGMT_K[@]}" -n "$WORKSPACE_NAMESPACE" get nkpclusters "$CLUSTER_NAME" --no-headers 2>/dev/null || true)
    if [[ $out == *Joined* ]]; then joined=1; break; fi
    sleep 10
  done
  if ((joined)); then ok "${CLUSTER_NAME} joined ${WORKSPACE_NAMESPACE}"
  else warn "${CLUSTER_NAME} has not joined yet. Check: kubectl --kubeconfig ${MGMT_KCFG} get nkpclusters -A"; fi

  info "Waiting for the platform applications on ${CLUSTER_NAME} (up to 30 minutes)..."
  if wait_helmreleases "$kcfg" "$WORKSPACE_NAMESPACE" 30; then
    ok "All platform applications are ready"
  else
    warn "Platform applications not ready after 30 minutes:"
    helmreleases_not_ready "$kcfg" "$WORKSPACE_NAMESPACE" | sed 's/^/      /' >&2 || true
    if ! remediate_apps "$kcfg" "$CLUSTER_NAME" "$WORKSPACE_NAMESPACE" "$MGMT_KCFG"; then
      warn "Some applications are still not ready."
      info "Add workers: nkp scale nodepools md-0 --replicas=<n> -c ${CLUSTER_NAME} -n ${WORKSPACE_NAMESPACE} --kubeconfig=${MGMT_KCFG}"
    fi
  fi
  cat >&2 <<EOF

    Next steps:
      export KUBECONFIG=${kcfg}
      kubectl get nodes
      NKP dashboard (on ${MGMT_CLUSTER_NAME}): workspace ${WORKSPACE_NAMESPACE} > Clusters > ${CLUSTER_NAME}
      Node pools: nkp get nodepools -c ${CLUSTER_NAME} -n ${WORKSPACE_NAMESPACE} --kubeconfig=${MGMT_KCFG}
      Another workload cluster: ${SCRIPT_PATH} --workload
EOF
}

phase_workload() {
  step "Workload cluster"
  command -v nkp >/dev/null || die "nkp CLI not found. Run the setup without --workload first."
  ensure_docker_access
  ensure_tmux_session
  PC_API_OK=0 TLS_MODE="" TRUST_ARGS=() NUTANIX_REGISTRY_ARGS=() NODE_CIDR="" NODE_POOLS=""
  BUNDLE_ARGS=() BUNDLE_FILES="" REGISTRY_MIRROR_ARGS=() NCR_URL="" NCR_AUTH=""
  load_mgmt_context
  CLUSTER_NAME="" CONTROLPLANE_IP="" SERVICE_LB_IP_RANGE=""
  ANSWERS_FILE="${WORKDIR}/nkp-workload.env"
  if load_config; then
    CLUSTER_NAME="" CONTROLPLANE_IP="" SERVICE_LB_IP_RANGE="" WORKSPACE_NAMESPACE=""
    apply_wl
  elif [[ -f $ANSWERS_FILE ]] && ask_yn "Found answers from a previous workload cluster. Use them as defaults?" Y; then
    # shellcheck disable=SC1090
    . "$ANSWERS_FILE"
  else
    info "Defaults come from the ${MGMT_CLUSTER_NAME} answers; the name and IP addresses must be new."
  fi
  PROXY_NO=""
  q_cluster
  q_workspace
  q_prism_central
  q_inventory
  q_network
  q_sizing workload
  q_mgmt_registry
  q_access
  q_extras
  save_answers
  ok "Answers saved to ${ANSWERS_FILE} (no passwords)"
  # shellcheck disable=SC2046
  capacity_check $(sizing_need)
  build_command
  show_summary
  export NUTANIX_USER NUTANIX_PASSWORD
  run_preflight
  run_create
  post_workload
}

# ---------------------------------------------------------------------------
# Destroy: workload clusters, the management cluster, then the subnet changes
# ---------------------------------------------------------------------------

restore_subnet() {
  local f pools dhcp now
  f=$(ip_plan_file)
  if [[ ! -f $f ]]; then info "No IP plan in ${WORKDIR}; the subnet was not changed by this script."; return 0; fi
  SUBNET_UUID=$(ip_plan_get IP_PLAN_SUBNET_UUID)
  pools=$(ip_plan_get IP_PLAN_ORIGINAL_POOLS)
  dhcp=$(ip_plan_get IP_PLAN_ORIGINAL_DHCP)
  if [[ -z $(ip_plan_get IP_PLAN_DNS) ]]; then dhcp="keep"
  elif [[ -z $dhcp || $dhcp == null ]]; then dhcp="unset"
  else dhcp="set:${dhcp}"; fi
  step "Restoring subnet $(ip_plan_get IP_PLAN_SUBNET)"
  now=$(py pc subnet-set "$SUBNET_UUID" --pools-json "${pools:-[]}" --dhcp "$dhcp") \
    || die "Restoring the subnet failed; ${f} is kept so you can rerun --destroy."
  ok "IPAM pool restored to ${now:-empty}"
}

pc_login_from_answers() { # TLS settings and password for Prism Central API calls outside the setup flow
  case ${TLS_MODE:-insecure} in
    trusted) PC_TLS=trusted ;;
    cafile)  PC_TLS="${CLUSTER_DIR}/prism-central-ca.pem" ;;
    *)       PC_TLS=insecure ;;
  esac
  PC_HOST=${NUTANIX_ENDPOINT#*://} PC_HOST=${PC_HOST%:*}
  local i code
  for i in 1 2 3; do
    ask_secret NUTANIX_PASSWORD "Prism Central password for ${NUTANIX_USER}"
    code=$(pc_status /api/nutanix/v3/users/me)
    if [[ $code == 200 ]]; then return 0; fi
    warn "Prism Central login failed (HTTP ${code})."
    NUTANIX_PASSWORD=""
  done
  die "Cannot log in to Prism Central."
}

phase_destroy() {
  step "Destroy the NKP lab"
  local f="${WORKDIR}/nkp-install.env" kcfg list ns name mgmt_ns=default boot confirm archive reachable=0
  [[ -f $f ]] || die "No answers at ${f}: nothing created by this script is known here (use --workdir)."
  # shellcheck disable=SC1090
  . "$f"
  CLUSTER_DIR="${WORKDIR}/${CLUSTER_NAME}"
  kcfg="${CLUSTER_DIR}/${CLUSTER_NAME}.conf"
  warn "This deletes ${CLUSTER_NAME}, every workload cluster it manages and all their VMs, then restores the subnet."
  if ((UNATTENDED)); then
    [[ ${NKP_DESTROY_CONFIRM:-} == "$CLUSTER_NAME" ]] \
      || die "--unattended --destroy needs NKP_DESTROY_CONFIRM=${CLUSTER_NAME} in the environment."
  else
    read -r -p "    Type the management cluster name (${CLUSTER_NAME}) to confirm: " confirm </dev/tty
    [[ $confirm == "$CLUSTER_NAME" ]] || die "Not confirmed; nothing was deleted."
  fi
  pc_login_from_answers
  export NUTANIX_USER NUTANIX_PASSWORD
  ensure_docker_access

  if [[ -f $kcfg ]] && list=$(py k8s clusters --kubeconfig "$kcfg" 2>/dev/null); then
    reachable=1
  fi
  if ((reachable)); then
    while IFS=$'\t' read -r -u 3 ns name; do
      if [[ $name == "$CLUSTER_NAME" ]]; then mgmt_ns=$ns; fi
      [[ -n $name && $name != "$CLUSTER_NAME" ]] || continue
      step "Deleting workload cluster ${name} (namespace ${ns})"
      nkp delete cluster -c "$name" -n "$ns" --kubeconfig="$kcfg" >&2 || warn "nkp delete cluster ${name} reported an error."
      kubectl --kubeconfig "$kcfg" -n "$ns" wait --for=delete "clusters.cluster.x-k8s.io/${name}" --timeout=30m >&2 \
        || die "${name} is still being deleted. Rerun --destroy once it is gone."
    done 3<<<"$list"

    step "Deleting management cluster ${CLUSTER_NAME}"
    if [[ $(nkp delete cluster --help 2>&1 || true) == *--self-managed* ]]; then
      nkp delete cluster -c "$CLUSTER_NAME" -n "$mgmt_ns" --self-managed --kubeconfig="$kcfg" >&2 \
        || die "Deleting ${CLUSTER_NAME} failed; the subnet was not restored. Rerun --destroy."
    else
      boot="${WORKDIR}/bootstrap.conf"
      info "Moving the cluster's Cluster API objects to a local bootstrap cluster, which then deletes it."
      nkp create bootstrap --kubeconfig="$boot" >&2 || die "nkp create bootstrap failed."
      nkp move capi-resources --from-kubeconfig="$kcfg" --to-kubeconfig="$boot" >&2 \
        || die "nkp move capi-resources failed; ${CLUSTER_NAME} is untouched. Remove the bootstrap with: nkp delete bootstrap --kubeconfig=${boot}"
      nkp delete cluster -c "$CLUSTER_NAME" -n "$mgmt_ns" --kubeconfig="$boot" >&2 \
        || die "Deleting ${CLUSTER_NAME} failed. Its objects are on the bootstrap cluster (${boot}); retry: nkp delete cluster -c ${CLUSTER_NAME} -n ${mgmt_ns} --kubeconfig=${boot}"
      nkp delete bootstrap --kubeconfig="$boot" >&2 || warn "Could not remove the bootstrap cluster: nkp delete bootstrap --kubeconfig=${boot}"
    fi
    ok "${CLUSTER_NAME} deleted"
  else
    warn "${CLUSTER_NAME} is not reachable with ${kcfg}; no cluster was deleted."
    ask_yn "Restore the subnet anyway?" N || exit 1
  fi

  restore_subnet
  archive="${WORKDIR}/archive-$(date +%Y%m%d-%H%M%S)"
  mkdir -m 700 "$archive"
  for f in nkp-ip-plan.env nkp-install.env nkp-workload.env lab-summary.txt "${CLUSTER_NAME}/harbor-push.env"; do
    if [[ -f ${WORKDIR}/${f} ]]; then mv "${WORKDIR}/${f}" "$archive/"; fi
  done
  ok "Answers, IP plan and Harbor push record moved to ${archive}"
}

# ---------------------------------------------------------------------------
# --check: read-only readiness tests for a real lab (nothing is created or changed)
# ---------------------------------------------------------------------------

CHECK_RESULTS=()
CHECK_PY=0

res() { # PASS|WARN|FAIL|SKIP "check" "detail"
  local c=$C_G
  case $1 in WARN) c=$C_Y ;; FAIL) c=$C_R ;; SKIP) c="" ;; esac
  printf '    %s%-4s%s  %-28s %s\n' "$c" "$1" "$C_0" "$2" "$3" >&2
  CHECK_RESULTS+=("$1  $2: $3")
}

check_host() {
  step "Jump host"
  local mem_kb free_kb cpus v help
  if [[ $(uname -s) != Linux ]]; then
    res WARN "Operating system" "$(uname -s); NKP needs a Linux jump host"
  elif [[ $(stat -fc %T /sys/fs/cgroup 2>/dev/null || true) == cgroup2fs ]]; then
    res PASS "cgroups v2" "enabled"
  else
    res FAIL "cgroups v2" "not enabled; the setup (without --check) configures it"
  fi
  if [[ -r /proc/meminfo ]]; then
    cpus=$(nproc) mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    if ((cpus >= 4)); then res PASS "CPUs" "$cpus"; else res WARN "CPUs" "${cpus}; the bootstrap cluster needs 4"; fi
    if ((mem_kb >= 4 * 1024 * 1024)); then res PASS "Available memory" "$((mem_kb / 1024 / 1024)) GiB"
    else res WARN "Available memory" "$((mem_kb / 1024)) MiB; the bootstrap cluster needs 4 GiB"; fi
  fi
  free_kb=$(df -Pk /var/lib 2>/dev/null | awk 'NR==2 {print $4}' || true)
  if [[ -n $free_kb ]]; then
    if ((free_kb >= 30 * 1024 * 1024)); then res PASS "Free space /var/lib" "$((free_kb / 1024 / 1024)) GiB"
    else res WARN "Free space /var/lib" "$((free_kb / 1024 / 1024)) GiB; 30 GiB or more recommended (Docker images)"; fi
  fi
  if command -v python3 >/dev/null && python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
    CHECK_PY=1
    res PASS "python3" "$(python3 -c 'import platform; print(platform.python_version())')"
  else
    res FAIL "python3" "3.9 or newer is needed for nkp_lab.py; run the setup with --prereqs-only"
  fi
  if docker info >/dev/null 2>&1; then
    v=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
    if [[ $v == "$DOCKER_VERSION" ]]; then res PASS "Docker" "$v"; else res WARN "Docker" "${v}; NKP ${NKP_MINOR} is tested with ${DOCKER_VERSION}"; fi
  elif command -v docker >/dev/null; then
    res FAIL "Docker" "installed, but this user cannot reach the daemon (docker group? log out and in)"
  else
    res FAIL "Docker" "not installed; run the setup with --prereqs-only"
  fi
  if command -v kubectl >/dev/null; then res PASS "kubectl" "$(kubectl version --client 2>/dev/null | head -1 || true)"
  else res FAIL "kubectl" "not installed; run the setup with --prereqs-only"; fi
  if command -v nkp >/dev/null; then
    v=$(nkp_release)
    if [[ $v == v"${NKP_MINOR}".* ]]; then res PASS "nkp CLI" "$v"; else res FAIL "nkp CLI" "nkp version reports ${v:-no nkp: line}; expected v${NKP_MINOR}.x"; fi
    help=$(nkp create cluster nutanix --help 2>&1 || true)
    if [[ $help == *--bundle* && $help == *--registry-mirror-url* ]]; then res PASS "nkp create flags" "--bundle, --registry-mirror-url"
    else res FAIL "nkp create flags" "no --bundle or --registry-mirror-url in 'nkp create cluster nutanix --help'"; fi
    help=$(nkp push bundle --help 2>&1 || true)
    if [[ $help == *--to-registry* ]]; then res PASS "nkp push bundle" "--to-registry available"
    else res FAIL "nkp push bundle" "no --to-registry in 'nkp push bundle --help'"; fi
  else
    res FAIL "nkp CLI" "not on PATH; run the setup with --prereqs-only (it installs nkp from the NKP package)"
  fi
  if command -v tmux >/dev/null; then res PASS "tmux" "installed"; else res WARN "tmux" "missing; long runs stop if SSH drops"; fi
  v=${SSH_PUBLIC_KEY:-${HOME}/.ssh/id_ed25519.pub}
  if [[ -r $v ]]; then res PASS "SSH public key" "$v"; else res WARN "SSH public key" "${v} missing; the setup generates it"; fi
}

check_selftest() {
  step "nkp_lab.py self-test (offline)"
  local dir out
  dir=$(dirname "$SCRIPT_PATH")
  if ((!CHECK_PY)); then res SKIP "Self-test" "no python3"; return 0; fi
  if [[ ! -r $dir/test_nkp_lab.py ]]; then res WARN "Self-test" "test_nkp_lab.py is not next to the script"; return 0; fi
  if out=$(cd "$dir" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_nkp_lab 2>&1); then
    res PASS "Self-test" "$(grep -m1 '^Ran ' <<<"$out" || echo ok)"
  else
    res FAIL "Self-test" "$(grep -m1 -E '^(FAILED|Ran )' <<<"$out" || echo failed)"
    grep -E '^(FAIL|ERROR):' <<<"$out" | head -5 | sed 's/^/          /' >&2 || true
  fi
}

check_bundle() {
  step "Image bundle"
  local dir files parts f kb=0 free_kb errf pkg d
  if [[ ${USE_BUNDLE:-} == N ]]; then res SKIP "Bundle" "USE_BUNDLE=N: images come from the internet"; return 0; fi
  dir=${BUNDLE_DIR_ARG:-${BUNDLE_DIR:-}}
  [[ -n $dir && -d $dir ]] || dir=$(bundle_candidates | awk 'NR == 1')
  if [[ -z $dir ]]; then
    pkg=${PACKAGE:-$(for d in "$PWD" "$HOME" "$HOME/Downloads"; do
      find "$d" -maxdepth 1 -type f -name 'nkp[_-]*linux_amd64.tar.gz' 2>/dev/null; done | sort -rV | awk 'NR == 1')}
    if [[ -n $pkg && -r $pkg && $(basename "$pkg") == nkp*bundle_v"${NKP_MINOR}".* ]]; then
      kb=$(du -kL "$pkg" | awk '{print $1}')
      free_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || true)
      if [[ -n $free_kb ]] && ((free_kb < kb * 11 / 10)); then
        res FAIL "Bundle" "${pkg} ($((kb / 1024 / 1024)) GiB) is not extracted, and ${HOME} has only $((free_kb / 1024 / 1024)) GiB free to extract it"
      else
        res WARN "Bundle" "${pkg} ($((kb / 1024 / 1024)) GiB) is not extracted yet; --prereqs-only extracts it into ${HOME}/nkp-dist"
      fi
    elif [[ ${USE_BUNDLE:-} == Y ]]; then res FAIL "Bundle" "USE_BUNDLE=Y, but no nkp-v${NKP_MINOR}.x/container-images found (--bundle-dir DIR)"
    else res WARN "Bundle" "no nkp-v${NKP_MINOR}.x/container-images under ${HOME}/nkp-dist or ${HOME}: images would come from the internet"; fi
    return 0
  fi
  errf=$(mktemp)
  if files=$(bundle_files "$dir" 2>"$errf"); then
    IFS=, read -r -a parts <<<"$files"
    for f in "${parts[@]}"; do kb=$((kb + $(du -kL "$f" | awk '{print $1}'))); done
    res PASS "Bundle" "${#parts[@]} files, $((kb / 1024 / 1024)) GiB in ${dir}"
    for f in "${parts[@]}"; do info "            $(basename "$f")"; done
    free_kb=$(df -Pk /var/lib 2>/dev/null | awk 'NR==2 {print $4}' || true)
    if [[ -n $free_kb ]] && ((free_kb < kb + 30 * 1024 * 1024)); then
      res WARN "Space for the bundle" "/var/lib has $((free_kb / 1024 / 1024)) GiB; the bootstrap loads $((kb / 1024 / 1024)) GiB of images"
    fi
  else
    res FAIL "Bundle" "$(tr -s ' \n' ' ' <"$errf")"
  fi
  rm -f "$errf"
}

check_pc() { # -> 1 when the later Prism Central checks cannot run
  step "Prism Central"
  local rc=0 code names=() uuids=() name uuid label cidr pools i found="" imgs=() cands=() scs=() hint sub=${SUBNET:-}
  if ((!CHECK_PY)); then res SKIP "Prism Central" "no python3"; return 1; fi
  [[ -n ${NUTANIX_ENDPOINT:-} ]] || { res FAIL "Prism Central" "NUTANIX_ENDPOINT is not set"; return 1; }
  NUTANIX_ENDPOINT=$(normalize_endpoint "$NUTANIX_ENDPOINT")
  PC_HOST=${NUTANIX_ENDPOINT#*://} PC_HOST=${PC_HOST%:*}
  py tls probe "$NUTANIX_ENDPOINT" || rc=$?
  case $rc in
    0) res PASS "Reachable, TLS" "${NUTANIX_ENDPOINT}, certificate trusted" ;;
    1) res WARN "Reachable, TLS" "${NUTANIX_ENDPOINT}, certificate not trusted here (the setup offers insecure or fetching it)" ;;
    *) res FAIL "Reachable" "cannot connect to ${NUTANIX_ENDPOINT} (routing, firewall, DNS)"; return 1 ;;
  esac
  case ${TLS_MODE:-insecure} in
    trusted) PC_TLS=trusted ;;
    cafile)  PC_TLS=${PC_CA_FILE:-insecure} ;;
    *)       PC_TLS=insecure ;;
  esac
  NUTANIX_USER=${NUTANIX_USER:-admin}
  if [[ -z ${NUTANIX_PASSWORD:-} ]] && ((UNATTENDED)); then res FAIL "Login" "export NUTANIX_PASSWORD"; return 1; fi
  ask_secret NUTANIX_PASSWORD "Prism Central password for ${NUTANIX_USER}"
  code=$(pc_status /api/nutanix/v3/users/me)
  if [[ $code != 200 ]]; then res FAIL "Login" "HTTP ${code} for ${NUTANIX_USER}"; return 1; fi
  res PASS "Login" "as ${NUTANIX_USER}"

  while IFS=$'\t' read -r name uuid; do
    if [[ -n $name ]]; then names+=("$name"); uuids+=("$uuid"); fi
  done < <(py pc clusters 2>/dev/null || true)
  if [[ -z ${NUTANIX_CLUSTER:-} && ${#names[@]} == 1 ]]; then NUTANIX_CLUSTER=${names[0]}; fi
  for i in "${!names[@]}"; do if [[ ${names[$i]} == "${NUTANIX_CLUSTER:-}" ]]; then PE_UUID=${uuids[$i]}; fi; done
  if [[ -n $PE_UUID ]]; then res PASS "Prism Element" "$NUTANIX_CLUSTER"
  else res FAIL "Prism Element" "'${NUTANIX_CLUSTER:-}' not found; clusters: ${names[*]:-none}"; return 1; fi

  names=()
  while IFS=$'\t' read -r name uuid label cidr pools; do
    [[ -n $name ]] || continue
    names+=("$name")
    if [[ $name == "${SUBNET:-}" ]] || [[ -z $found && ${name,,} == "${sub,,}" ]] \
       || [[ -z $found && -z ${SUBNET:-} && ${name,,} =~ ^primary(-|$) ]]; then
      found=$name SUBNET_UUID=$uuid NODE_CIDR=$cidr NODE_POOLS=$pools
    fi
  done < <(py pc subnets "$NUTANIX_CLUSTER" 2>/dev/null || true)
  if [[ -z $found ]]; then
    hint=$(printf '%s\n' "${names[@]}" | awk -v w="${sub,,}" 'index(tolower($0), w) == 1 {print; exit}')
    res FAIL "Subnet" "'${SUBNET:-}' not found on ${NUTANIX_CLUSTER}${hint:+; set SUBNET=${hint}}; subnets: ${names[*]:-none}"
  elif [[ -n ${SUBNET:-} && $found != "$SUBNET" ]]; then
    res WARN "Subnet" "SUBNET=${SUBNET} matches '${found}' only ignoring case; set SUBNET=${found}"
  elif [[ -z $NODE_POOLS ]]; then res WARN "Subnet" "${found} has no IPAM pool: nodes need DHCP, and no IP plan is made"
  else res PASS "Subnet" "${found}: ${NODE_CIDR}, IPAM pool ${NODE_POOLS}"; fi
  SUBNET=${found:-${SUBNET:-}}

  mapfile -t imgs < <(py pc images 2>/dev/null || true)
  if [[ -n ${VM_IMAGE:-} ]]; then
    if printf '%s\n' "${imgs[@]}" | grep -qxF -- "$VM_IMAGE"; then
      if [[ $VM_IMAGE == *"$K8S_VERSION_HINT"* ]]; then res PASS "Node image" "$VM_IMAGE"
      else res WARN "Node image" "${VM_IMAGE} has no ${K8S_VERSION_HINT} in its name; preflight may reject it"; fi
    else
      res FAIL "Node image" "'${VM_IMAGE}' not in Prism Central"
    fi
  else
    mapfile -t cands < <(printf '%s\n' "${imgs[@]}" | grep -F -- "$K8S_VERSION_HINT" || true)
    case ${#cands[@]} in
      0) res FAIL "Node image" "no image with ${K8S_VERSION_HINT} in its name; upload the NKP Rocky/Ubuntu image" ;;
      1) res PASS "Node image" "${cands[0]}" ;;
      *) res WARN "Node image" "${#cands[@]} images match ${K8S_VERSION_HINT}; set VM_IMAGE (${cands[*]})" ;;
    esac
  fi

  mapfile -t scs < <(py pc containers "$NUTANIX_CLUSTER" 2>/dev/null || true)
  if printf '%s\n' "${scs[@]}" | grep -qxF -- "${STORAGE_CONTAINER_NAME:-default}"; then
    res PASS "Storage container" "${STORAGE_CONTAINER_NAME:-default}"
  else
    res FAIL "Storage container" "'${STORAGE_CONTAINER_NAME:-default}' not on ${NUTANIX_CLUSTER}; containers: ${scs[*]:-none}"
  fi

  if [[ -n ${NTP_SERVERS:-} ]]; then res PASS "NTP" "${NTP_SERVERS} (from the settings)"
  elif name=$(py pc ntp "$NUTANIX_CLUSTER" 2>/dev/null) && [[ -n $name ]]; then res PASS "NTP" "${name} (from Prism Central)"
  else res WARN "NTP" "none configured in Prism Central; set NTP_SERVERS or keep the image defaults"; fi
  return 0
}

check_ip_plan() {
  step "IP addresses and DNS (dry run)"
  local rc=0 f v k r
  local IP_PLAN_COUNT="" IP_PLAN_BLOCK="" MGMT_CONTROLPLANE_IP="" WL_CONTROLPLANE_IP="" MGMT_LB_RANGE="" WL_LB_RANGE=""
  local POOLS="" DNS_VM_IP="" DNS_OK=N IP_PLAN_NEW_POOLS IP_PLAN_ORIGINAL_POOLS IP_PLAN_ORIGINAL_DHCP
  [[ -n $SUBNET_UUID ]] || { res SKIP "IP plan" "no subnet"; return 0; }
  py_vars pc ip-plan "$SUBNET_UUID" --pc-host "$PC_HOST" --max "$IP_PLAN_MAX" --min "$IP_PLAN_MIN" \
    --reserve "$IP_PLAN_NODE_RESERVE" --dns-vm "$LAB_DNS_VM" --domain "$LAB_DOMAIN" 2>/dev/null || rc=$?
  f=$(ip_plan_file)
  if [[ -f $f && $(ip_plan_get IP_PLAN_SUBNET_UUID) == "$SUBNET_UUID" ]]; then
    v=$(ip_plan_get IP_PLAN_BLOCK)
    if [[ -n $NODE_POOLS ]] && ipcalc range_overlaps "$v" "$NODE_POOLS"; then
      res FAIL "IP plan" "${f}: block ${v} overlaps the IPAM pool ${NODE_POOLS} again"
    else
      res PASS "IP plan" "applied earlier: ${v} is outside the IPAM pool"
    fi
  elif [[ -n ${CONTROLPLANE_IP:-} ]]; then
    for k in CONTROLPLANE_IP SERVICE_LB_IP_RANGE WL_CONTROLPLANE_IP WL_LB_RANGE; do
      v=${!k:-}
      [[ -n $v ]] || continue
      r=$v; [[ $r == *-* ]] || r="${r}-${r}"
      if [[ -n $NODE_CIDR ]] && ! ipcalc range_in_cidr "$r" "$NODE_CIDR"; then res FAIL "$k" "${v} is outside ${NODE_CIDR}"
      elif [[ -n $NODE_POOLS ]] && ipcalc range_overlaps "$r" "$NODE_POOLS"; then res FAIL "$k" "${v} is inside the IPAM pool ${NODE_POOLS}"
      elif ip_responds "${r%%-*}"; then res FAIL "$k" "${r%%-*} answers ping: in use"
      else res PASS "$k" "$v"; fi
    done
  else
    case $rc in
      0) res PASS "IP plan" "would reserve ${IP_PLAN_BLOCK} (${IP_PLAN_COUNT}): mgmt API ${MGMT_CONTROLPLANE_IP}, LB ${MGMT_LB_RANGE}; workload API ${WL_CONTROLPLANE_IP}, LB ${WL_LB_RANGE}" ;;
      3) res WARN "IP plan" "no IPAM pool on ${SUBNET}: set CONTROLPLANE_IP, SERVICE_LB_IP_RANGE and the WL_* addresses" ;;
      4) res FAIL "IP plan" "no run of ${IP_PLAN_MIN} free addresses in ${NODE_POOLS} (keeping ${IP_PLAN_NODE_RESERVE} for nodes)" ;;
      5) res FAIL "IP plan" "every candidate block has addresses answering ping" ;;
      *) res FAIL "IP plan" "could not read subnet ${SUBNET}" ;;
    esac
  fi
  if [[ $rc != 0 ]]; then res SKIP "Lab DNS" "not checked"
  elif [[ -z $DNS_VM_IP ]]; then res WARN "Lab DNS" "no VM named '${LAB_DNS_VM}' with an IPv4 address; the subnet's DNS stays as is"
  elif [[ $DNS_OK == Y ]]; then res PASS "Lab DNS" "${LAB_DNS_VM} (${DNS_VM_IP}) resolves ${LAB_DOMAIN}"
  else res WARN "Lab DNS" "${LAB_DNS_VM} (${DNS_VM_IP}) does not resolve ${LAB_DOMAIN} from this host"; fi
}

# shellcheck disable=SC2030,SC2031  # sizing is computed in subshells so the real answers stay untouched
check_capacity() {
  step "Capacity of ${NUTANIX_CLUSTER}"
  if [[ ! -f ${WORKDIR}/${CLUSTER_NAME}/${CLUSTER_NAME}.conf ]]; then
    case ${SIZING:-pro} in
      starter) res FAIL "Management sizing" "SIZING=starter (4 vCPU / 8 GiB workers) is too small: Kommander times out, no room for Harbor; set SIZING=pro" ;;
      custom) if ((${WK_VCPUS:-8} < 8 || ${WK_MEMORY:-32} < 32)); then
                res WARN "Management sizing" "workers ${WK_VCPUS:-8} vCPU / ${WK_MEMORY:-32} GiB are below the Pro default (8 vCPU / 32 GiB)"
              else res PASS "Management sizing" "custom: ${WK_REPLICAS:-4} workers, ${WK_VCPUS:-8} vCPU / ${WK_MEMORY:-32} GiB"; fi ;;
      *) res PASS "Management sizing" "pro: 3 x 4 vCPU / 16 GiB control plane, 4 x 8 vCPU / 32 GiB workers" ;;
    esac
  fi
  local n=0 c=0 m=0 n2 c2 m2 disk cvm usable what="management + workload"
  local HOSTS="" CORES=0 HOST_MEM_GIB=0 VM_VCPU=0 VM_MEM_GIB=0 SC_FREE_GIB="" VMS_OK=N
  [[ -n $PE_UUID ]] || { res SKIP "Capacity" "no Prism Element"; return 0; }
  if [[ ! -f ${WORKDIR}/${CLUSTER_NAME:-nkp-mgmt}/${CLUSTER_NAME:-nkp-mgmt}.conf ]]; then
    read -r n c m <<<"$(set +u; SIZING=${SIZING:-pro}; sizing_need)"
  else
    what="workload (management cluster exists)"
  fi
  read -r n2 c2 m2 <<<"$(set +u; swap_wl; SIZING=${SIZING:-starter}; sizing_need)"
  n=$((n + n2)) c=$((c + c2)) m=$((m + m2)) disk=$((n * NODE_DISK_GIB))
  if [[ ${USE_BUNDLE:-} != N || -n ${REGISTRY_MIRROR_URL:-} ]]; then disk=$((disk + HARBOR_DISK_GIB)); fi
  py_vars pc capacity "$PE_UUID" "${STORAGE_CONTAINER_NAME:-default}" 2>/dev/null || true
  if [[ -z $HOSTS ]] || ((HOSTS == 0 || HOST_MEM_GIB == 0)); then res WARN "Capacity" "could not read the hosts of ${NUTANIX_CLUSTER}"; return 0; fi
  cvm=$((HOSTS * CVM_RESERVE_GIB))
  usable=$(((HOST_MEM_GIB - VM_MEM_GIB - cvm) * 90 / 100))
  info "${what}: ${n} VMs, ${c} vCPU, ${m} GiB memory, ${disk} GiB disk"
  if ((m <= usable)); then res PASS "Memory" "${m} GiB needed, about ${usable} GiB free (${HOSTS} hosts, CVMs and 10% kept)"
  else res FAIL "Memory" "${m} GiB needed, about ${usable} GiB free; choose a smaller size or free memory"; fi
  if ((CORES > 0 && VM_VCPU + c > CORES * 4)); then res WARN "vCPU" "overcommit $(((VM_VCPU + c) / CORES)):1 on ${CORES} cores"
  else res PASS "vCPU" "$((VM_VCPU + c)) on ${CORES} cores"; fi
  if [[ -z $SC_FREE_GIB ]]; then res WARN "Storage" "could not read the free space of ${STORAGE_CONTAINER_NAME:-default}"
  elif ((disk > SC_FREE_GIB)); then res WARN "Storage" "up to ${disk} GiB (thin), about ${SC_FREE_GIB} GiB free"
  else res PASS "Storage" "up to ${disk} GiB, about ${SC_FREE_GIB} GiB free"; fi
}

check_registry() {
  step "Registry ${REGISTRY_MIRROR_URL}"
  local proj repos who
  if ((!CHECK_PY)); then res SKIP "Registry" "no python3"; return 0; fi
  HARBOR_URL=${REGISTRY_MIRROR_URL%/} HARBOR_CACERT=${REGISTRY_MIRROR_CACERT:-} HARBOR_USER=${REGISTRY_MIRROR_USERNAME:-admin}
  if [[ -n $HARBOR_CACERT && ! -r $HARBOR_CACERT ]]; then res FAIL "Registry CA" "cannot read ${HARBOR_CACERT}"; return 0; fi
  if hpy ping 2>/dev/null; then res PASS "Registry reachable" "${HARBOR_URL}${HARBOR_CACERT:+ (CA ${HARBOR_CACERT})}"
  else res FAIL "Registry reachable" "${HARBOR_URL} does not answer, or its certificate does not match ${HARBOR_CACERT:-the system trust store}"; return 0; fi
  if [[ -z ${REGISTRY_MIRROR_PASSWORD:-} ]] && ((UNATTENDED)); then res SKIP "Registry login" "export REGISTRY_MIRROR_PASSWORD"; return 0; fi
  ask_secret REGISTRY_MIRROR_PASSWORD "Password of ${HARBOR_USER} on ${HARBOR_URL}"
  HARBOR_PASSWORD=$REGISTRY_MIRROR_PASSWORD
  if who=$(hpy whoami 2>/dev/null); then res PASS "Registry login" "as ${who:-$HARBOR_USER}"
  else res FAIL "Registry login" "${HARBOR_USER} rejected"; return 0; fi
  proj=$(harbor_project "$HARBOR_URL")
  if [[ -z $proj ]]; then res FAIL "Registry project" "${HARBOR_URL} has no project path (e.g. .../nkp)"
  elif repos=$(hpy repos "$proj" 2>/dev/null); then res PASS "Registry project" "${proj}: ${repos} repositories"
  else res WARN "Registry project" "${proj} does not exist yet; the push creates it"; fi
}

check_mgmt() {
  local m=${CLUSTER_NAME:-nkp-mgmt} kcfg out rc=0 ca
  local CNPG_APP="" HARBOR_APP="" ROOK_ENABLED=N ROOK_OVERRIDES="" OBJECT_STORE=N NCR_HOST="" NCR_PRESENT=N NCR_CA_FOUND=N
  kcfg="${WORKDIR}/${m}/${m}.conf"
  step "Management cluster ${m}"
  if [[ ! -f $kcfg ]]; then res SKIP "Management cluster" "not created yet (${kcfg})"; return 0; fi
  if ((!CHECK_PY)); then res SKIP "Management cluster" "no python3"; return 0; fi
  if out=$(py k8s clusters --kubeconfig "$kcfg" 2>/dev/null); then res PASS "Kubernetes API" "$(grep -c . <<<"$out") Cluster API clusters"
  else res FAIL "Kubernetes API" "cannot reach ${m} with ${kcfg}"; return 0; fi
  out=$(helmreleases_not_ready "$kcfg" kommander) || rc=$?
  if ((rc)); then res WARN "Platform apps" "no HelmReleases in kommander yet"
  elif [[ -z $out ]]; then res PASS "Platform apps" "all HelmReleases in kommander Ready"
  else res WARN "Platform apps" "not Ready: $(cut -f1 <<<"$out" | paste -sd' ' -)"; fi
  py_vars k8s harbor-prereqs --kubeconfig "$kcfg" 2>/dev/null || true
  if [[ -n $NCR_HOST ]]; then res PASS "Ingress" "$NCR_HOST"; else res FAIL "Ingress" "no address in kommandercluster status yet"; fi
  if [[ $NCR_PRESENT == Y ]]; then
    ca=$(mktemp)
    py_vars k8s ncr --kubeconfig "$kcfg" --ca-out "$ca" 2>/dev/null || true
    HARBOR_URL="https://${NCR_HOST}:${NCR_PORT}/${HARBOR_PROJECT}" HARBOR_CACERT=$ca
    if hpy ping 2>/dev/null; then res PASS "Harbor" "running, answers at ${HARBOR_URL}"
    else res FAIL "Harbor" "secret in ncr-system exists, but ${HARBOR_URL} does not answer with the ingress CA"; fi
    rm -f "$ca"
  elif [[ -z ${REGISTRY_MIRROR_URL:-} ]]; then
    if [[ -n $CNPG_APP && -n $HARBOR_APP ]]; then res PASS "Harbor apps" "${CNPG_APP}, ${HARBOR_APP} (not deployed yet)"
    else res FAIL "Harbor apps" "missing ClusterApp: ${CNPG_APP:-cloudnative-pg} ${HARBOR_APP:-harbor}"; fi
    if [[ $ROOK_ENABLED != Y ]]; then res WARN "Rook Ceph" "rook-ceph-cluster is not enabled; Harbor needs S3 storage"
    elif [[ -n $ROOK_OVERRIDES ]]; then res WARN "Rook Ceph" "already has overrides (${ROOK_OVERRIDES}); not enlarged to ${CEPH_OSD_COUNT} volumes"
    else res PASS "Rook Ceph" "enabled; the deploy raises it to ${CEPH_OSD_COUNT} x 40 GiB"; fi
    if [[ -n $HARBOR_OVERRIDES_FILE ]]; then res PASS "Harbor values" "$HARBOR_OVERRIDES_FILE"
    elif [[ $OBJECT_STORE == Y ]]; then res PASS "Object store" "storage class dkp-object-store"
    else res WARN "Object store" "no storage class dkp-object-store; set HARBOR_OVERRIDES_FILE"; fi
  fi
  if [[ -f $(harbor_marker "$m") ]]; then
    res PASS "Bundle pushed" "$(harbor_marker_get "$m" HARBOR_URL) on $(harbor_marker_get "$m" PUSH_DATE)"
  else
    res WARN "Bundle pushed" "not yet; the setup or --harbor pushes it, otherwise workload clusters pull from the internet"
  fi
}

phase_check() {
  local src="" f passes warns fails
  step "NKP ${NKP_MINOR} lab check (read-only: nothing is created or changed)"
  if [[ -n $CONFIG_FILE ]]; then src=$CONFIG_FILE
  elif [[ -f ${WORKDIR}/nkp-install.env ]]; then src=${WORKDIR}/nkp-install.env
  elif [[ -f ./nkp-lab.env ]]; then src=$(readlink -f ./nkp-lab.env); fi
  if [[ -n $src ]]; then
    # shellcheck disable=SC1090
    . "$src"
    info "Settings from ${src}"
  else
    warn "No --config, ${WORKDIR}/nkp-install.env or ./nkp-lab.env: only the jump host and the bundle are checked."
  fi
  CHECK_RESULTS=() PE_UUID="" SUBNET_UUID="" NODE_POOLS="" NODE_CIDR=""
  check_host
  check_selftest
  check_bundle
  if [[ -n $src ]] && check_pc; then
    check_ip_plan
    check_capacity
  fi
  if [[ -n ${REGISTRY_MIRROR_URL:-} ]]; then check_registry; fi
  if [[ -n $src ]]; then check_mgmt; fi

  passes=$(printf '%s\n' "${CHECK_RESULTS[@]}" | grep -c '^PASS' || true)
  warns=$(printf '%s\n' "${CHECK_RESULTS[@]}" | grep -c '^WARN' || true)
  fails=$(printf '%s\n' "${CHECK_RESULTS[@]}" | grep -c '^FAIL' || true)
  mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
  f="${WORKDIR}/lab-check.txt"
  (umask 077; { echo "NKP ${NKP_MINOR} lab check $(date '+%F %T'), settings: ${src:-none}"; printf '%s\n' "${CHECK_RESULTS[@]}"; } >"$f")
  step "Result: ${passes} passed, ${warns} warnings, ${fails} failed (report: ${f})"
  if ((fails)); then
    printf '%s\n' "${CHECK_RESULTS[@]}" | grep '^FAIL' | sed 's/^FAIL  /    - /' >&2
    exit 1
  fi
  if ((warns)); then ok "Ready to deploy; review the warnings above."; else ok "Ready to deploy."; fi
}

main() {
  parse_args "$@"
  if ((INIT_CONFIG)); then init_config; return 0; fi
  [[ -r $PY_HELPER ]] || die "Missing ${PY_HELPER}: keep nkp_lab.py next to this script."
  if ((CHECK)); then phase_check; return 0; fi
  if ((STATUS_ONLY)); then phase_status; return 0; fi
  if ((DESTROY)); then phase_destroy; return 0; fi
  if ((WORKLOAD)); then phase_workload; return 0; fi
  if ((HARBOR_ONLY)); then phase_harbor; return 0; fi
  if ((DO_PREREQS)); then phase_prereqs; fi
  if ((!DO_SETUP)); then return 0; fi
  if ((LAB)); then phase_lab; else phase_setup; fi
  return 0
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
