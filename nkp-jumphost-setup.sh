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
# Images: with the air-gapped bundle (nkp-air-gapped-bundle_*) extracted, the management cluster is
#         created with --bundle, which seeds its internal registry (Harbor, namespace ncr-system); workload
#         clusters then pull from that registry instead of Docker Hub. Images outside the bundle still
#         come from the internet.
#
# Usage:
#   ./nkp-jumphost-setup.sh --lab [--config nkp-lab.env]
#   ./nkp-jumphost-setup.sh [--package nkp-bundle_v2.19.x_linux_amd64.tar.gz] [options]
#   ./nkp-jumphost-setup.sh --workload
#   ./nkp-jumphost-setup.sh --destroy
#
# Options:
#   --package PATH    NKP package from the Nutanix Portal (nkp_*, nkp-bundle_* or
#                     nkp-air-gapped-bundle_*.tar.gz). Auto-detected in the current
#                     directory, $HOME and $HOME/Downloads when omitted.
#   --bundle-dir DIR  container-images directory of the extracted air-gapped bundle. Default: found
#                     under $HOME/nkp-dist, where --package extracts nkp-air-gapped-bundle_*.
#   --workdir DIR     Where answers, logs and the kubeconfig are kept (default: $HOME/nkp).
#   --prereqs-only    Run phase 1 only.
#   --skip-prereqs    Run phase 2 only.
#   --print-only      Do everything except the final cluster creation; print the command.
#   --insecure        Do not verify Prism Central's TLS certificate, without asking.
#   --status          Show what is still not ready on a cluster this script already created.
#   --workload        Create a workload (managed) cluster on the management cluster this script
#                     created: it attaches to a workspace you choose. Run after the management cluster is up.
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
# DOCKERHUB_PASSWORD and NUTANIX_REGISTRY_PASSWORD (optional with the bundle) before running. The preflight dry-run manifest (cluster-dryrun.yaml,
# mode 600) does contain the credentials, because nkp renders them into Kubernetes secrets. If the jump host reaches the internet through a proxy,
# configure apt/dnf for it and export HTTP_PROXY/HTTPS_PROXY/NO_PROXY before running.

# shellcheck disable=SC2034  # arrays handed to pick() by name look unused to shellcheck
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
ORIG_ARGS=("$@")

NKP_MINOR="2.19"
DOCKER_VERSION="27.4.0"
KUBECTL_MINOR="1.36"
KUBECTL_FALLBACK="v1.36.2"
K8S_VERSION_HINT="1.36"
DOCKERHUB_URL="https://registry-1.docker.io"
NUTANIX_REGISTRY_DEFAULT_USER="svcregistrynkp"
MIN_WORKERS=4  # two 4 vCPU workers (the documented Starter minimum) leave Kommander apps Pending on CPU
NCR_PORT=5000
HARBOR_DISK_GIB=100  # internal registry storage recommended by the NKP docs

PACKAGE=""
WORKDIR="${HOME}/nkp"
DO_PREREQS=1
DO_SETUP=1
PRINT_ONLY=0
FORCE_INSECURE=0
STATUS_ONLY=0
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
REGISTRY_MIRROR_ARGS=()
NCR_URL=""
NCR_AUTH=""

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
      --workload)     WORKLOAD=1 TMUX_SESSION=nkp-workload ;;
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
# (the registry token is optional when the bundle seeds the internal registry).

# Management cluster
CLUSTER_NAME=nkp-mgmt
NUTANIX_ENDPOINT=                 # Prism Central, e.g. https://10.42.x.39:9440
NUTANIX_USER=admin
TLS_MODE=insecure                 # insecure | fetched | cafile (with PC_CA_FILE)
NUTANIX_CLUSTER=                  # Prism Element name; blank = the only one
SUBNET=Primary
VM_IMAGE=                         # blank = the only image whose name contains 1.36
STORAGE_CONTAINER_NAME=default
CONTROLPLANE_IP=                  # blank = from the IP plan
SERVICE_LB_IP_RANGE=              # blank = from the IP plan
POD_CIDR=192.168.0.0/16
SERVICE_CIDR=10.96.0.0/12
SIZING=starter                    # pro | starter | custom (then CP_* and WK_* below)
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

# Images: seed the management cluster's internal registry from the extracted air-gapped bundle
USE_BUNDLE=                       # Y | N; blank = Y when an extracted nkp-air-gapped-bundle is found
BUNDLE_DIR=                       # blank = ~/nkp-dist/nkp-air-gapped-bundle_v2.19.*/nkp-v*/container-images
USE_NDK_BUNDLE=N                  # Y also pushes ndk-*.tar (put it in BUNDLE_DIR); only if you deploy NDK

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

ipcalc() { # op args... -> exit status
  python3 - "$@" <<'PY'
import ipaddress, sys
op, *a = sys.argv[1:]
def rng(s):
    lo, hi = (ipaddress.ip_address(x.strip()) for x in s.split("-", 1))
    if hi < lo:
        raise ValueError
    return lo, hi
def rngs(s):
    return [rng(x) for x in s.split(",") if x.strip()]
try:
    if op == "ip":
        ipaddress.ip_address(a[0]); ok = True
    elif op == "cidr":
        ipaddress.ip_network(a[0], strict=False); ok = "/" in a[0]
    elif op == "range":
        rng(a[0]); ok = True
    elif op == "ip_in_cidr":
        ok = ipaddress.ip_address(a[0]) in ipaddress.ip_network(a[1], strict=False)
    elif op == "range_in_cidr":
        n = ipaddress.ip_network(a[1], strict=False); lo, hi = rng(a[0]); ok = lo in n and hi in n
    elif op == "ip_in_ranges":
        ip = ipaddress.ip_address(a[0]); ok = any(lo <= ip <= hi for lo, hi in rngs(a[1]))
    elif op == "range_in_ranges":
        lo, hi = rng(a[0]); ok = any(l <= lo and hi <= h for l, h in rngs(a[1]))
    elif op == "range_overlaps":
        lo, hi = rng(a[0]); ok = any(lo <= h and l <= hi for l, h in rngs(a[1]))
    elif op == "cidr_overlap":
        ok = ipaddress.ip_network(a[0], strict=False).overlaps(ipaddress.ip_network(a[1], strict=False))
    elif op == "range_first":
        print(rng(a[0])[0]); ok = True
    else:
        ok = False
except (ValueError, IndexError, TypeError):
    ok = False
sys.exit(0 if ok else 1)
PY
}

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
  ver=$(nkp version 2>&1 | head -5 || true)
  if grep -q "${NKP_MINOR}" <<<"$ver"; then ok "nkp CLI: $(head -1 <<<"$ver")"; else warn "nkp reports: ${ver//$'\n'/ }. Expected ${NKP_MINOR}.x."; fi
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

cfg_escape() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

pc_curl() {
  printf 'user = "%s:%s"\n' "$(cfg_escape "$NUTANIX_USER")" "$(cfg_escape "$NUTANIX_PASSWORD")" \
    | curl -K - -sS --max-time 30 "${PC_TLS_ARGS[@]}" -H 'Accept: application/json' "$@"
}

pc_api() { # METHOD PATH [JSON]
  local extra=()
  if [[ -n ${3-} ]]; then extra=(-H 'Content-Type: application/json' --data "$3"); fi
  pc_curl --fail -X "$1" "${extra[@]}" "${NUTANIX_ENDPOINT}$2"
}

pc_status() { pc_curl -o /dev/null -w '%{http_code}' "${NUTANIX_ENDPOINT}$1" 2>/dev/null || true; }

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
             USE_BUNDLE BUNDLE_DIR USE_NDK_BUNDLE USE_MGMT_REGISTRY; do
      printf '%s=%q\n' "$k" "${!k:-}"
    done
  } >"$ANSWERS_FILE"
  chmod 600 "$ANSWERS_FILE"
}

v_workload_name() {
  v_cluster_name "$1" || return 1
  if [[ $1 == "$MGMT_CLUSTER_NAME" ]]; then echo "      That is the management cluster's name." >&2; return 1; fi
  local names
  names=$("${MGMT_K[@]}" get clusters.cluster.x-k8s.io -A -o name 2>/dev/null || true)
  if grep -qx "cluster.cluster.x-k8s.io/$1" <<<"$names"; then
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
  TLS_MODE=insecure PC_TLS_ARGS=(-k) TRUST_ARGS=(--insecure=true)
  warn "NKP will not verify Prism Central's TLS certificate (--insecure)."
}

fetch_server_cert() { # out_pem -> Prism Central's own (leaf) certificate
  local hostport=${NUTANIX_ENDPOINT#*://} sni=()
  if [[ ! $PC_HOST =~ ^[0-9.]+$ ]]; then sni=(-servername "$PC_HOST"); fi
  openssl s_client "${sni[@]}" -connect "$hostport" </dev/null 2>/dev/null | openssl x509 -outform PEM >"$1"
}

cert_covers_host() { # pem host -> 0 issued for host, 1 not issued for host, 2 cannot tell; prints the certificate's names
  local rc=0
  python3 - "$1" "$2" 2>/dev/null <<'PY' || rc=$?
import ipaddress, ssl, sys
try:
    sans = ssl._ssl._test_decode_cert(sys.argv[1]).get("subjectAltName", ())
except Exception:
    sys.exit(2)
print(", ".join(f"{k}:{v}" for k, v in sans))
host = sys.argv[2].lower()
try:
    ip = ipaddress.ip_address(host)
except ValueError:
    ip = None
for kind, value in sans:
    value = value.strip().lower()
    if ip is not None and kind == "IP Address":
        try:
            if ipaddress.ip_address(value) == ip:
                sys.exit(0)
        except ValueError:
            pass
    elif ip is None and kind == "DNS":
        if value == host or (value.startswith("*.") and host.partition(".")[2] == value[2:]):
            sys.exit(0)
sys.exit(1)
PY
  return "$rc"
}

setup_trust() {
  local rc=0 pem tb_help b64file leaf names
  PC_TLS_ARGS=()
  if ((FORCE_INSECURE)); then
    curl -sk -o /dev/null --max-time 10 "${NUTANIX_ENDPOINT}/" || rc=$?
    ((rc == 0)) || die "Cannot reach ${NUTANIX_ENDPOINT} (curl exit ${rc}). Check routing, firewall and DNS from the jump host."
    use_insecure; return
  fi
  curl -s -o /dev/null --max-time 10 "${NUTANIX_ENDPOINT}/" || rc=$?
  case $rc in
    0) TLS_MODE=trusted; ok "Prism Central certificate is trusted by this host"; return ;;
    6|7|28) die "Cannot reach ${NUTANIX_ENDPOINT} (curl exit ${rc}). Check routing, firewall and DNS from the jump host." ;;
  esac
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
      PC_TLS_ARGS=(-k) leaf=$pem ;;
    cafile)
      ask PC_CA_FILE "Path to the CA certificate (PEM)" v_file
      openssl x509 -in "$PC_CA_FILE" -noout >/dev/null 2>&1 || die "${PC_CA_FILE} is not a PEM certificate."
      cp "$PC_CA_FILE" "$pem"
      PC_TLS_ARGS=(--cacert "$pem") leaf="${CLUSTER_DIR}/prism-central-server.pem"
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
  local pe_list=() subnets_json="" subnet_vals=() subnet_labels=() img_all=() img_list=() sc_list=() line pools name label
  CLUSTERS_JSON="" SUBNET_UUID="" PE_UUID=""
  if ((PC_API_OK)); then
    CLUSTERS_JSON=$(pc_api POST /api/nutanix/v3/clusters/list '{"kind":"cluster","length":500}' 2>/dev/null || true)
    mapfile -t pe_list < <(jq -r '.entities[] | select((.status.resources.config.service_list // []) | index("PRISM_CENTRAL") | not) | .status.name' \
      <<<"$CLUSTERS_JSON" 2>/dev/null | sort || true)
  fi
  pick NUTANIX_CLUSTER "Prism Element cluster for the nodes" pe_list
  PE_UUID=$(jq -r --arg c "$NUTANIX_CLUSTER" '[.entities[]? | select(.status.name == $c) | .metadata.uuid][0] // empty' \
    <<<"$CLUSTERS_JSON" 2>/dev/null || true)

  if ((PC_API_OK)); then
    subnets_json=$(pc_api POST /api/nutanix/v3/subnets/list '{"kind":"subnet","length":500}' 2>/dev/null || true)
    while IFS=$'\t' read -r name label; do
      if [[ -n $name ]]; then subnet_vals+=("$name"); subnet_labels+=("$label"); fi
    done < <(jq -r --arg c "$NUTANIX_CLUSTER" '
        .entities[]?
        | select(((.status.cluster_reference.name // .spec.cluster_reference.name // "") as $n | $n == $c or $n == ""))
        | .status.resources.ip_config as $ip
        | [.status.name,
           (.status.name + "  (" + (.status.resources.subnet_type // "?")
             + (if $ip.subnet_ip then ", " + $ip.subnet_ip + "/" + ($ip.prefix_length|tostring) else "" end)
             + (if ($ip.pool_list // []) | length > 0 then ", pool " + ([$ip.pool_list[].range | gsub(" "; "-")] | join(",")) else ", no IPAM pool" end)
             + ")")]
        | @tsv' <<<"$subnets_json" 2>/dev/null || true)
  fi
  default_match SUBNET subnet_vals '^primary$'
  pick SUBNET "Subnet for control plane and worker nodes (must have IPAM or DHCP)" subnet_vals subnet_labels

  NODE_POOLS=""
  if [[ -n $subnets_json ]]; then
    SUBNET_UUID=$(jq -r --arg s "$SUBNET" --arg c "$NUTANIX_CLUSTER" '
        [.entities[]? | select(.status.name == $s)
         | select(((.status.cluster_reference.name // .spec.cluster_reference.name // "") as $n | $n == $c or $n == ""))][0]
        | .metadata.uuid // empty' <<<"$subnets_json" 2>/dev/null || true)
    line=$(jq -r --arg s "$SUBNET" --arg c "$NUTANIX_CLUSTER" '
        [.entities[]? | select(.status.name == $s)
         | select(((.status.cluster_reference.name // .spec.cluster_reference.name // "") as $n | $n == $c or $n == ""))][0]
        | .status.resources.ip_config // {}
        | if .subnet_ip then "\(.subnet_ip)/\(.prefix_length) \([.pool_list[]?.range | gsub(" "; "-")] | join(","))" else "" end' \
        <<<"$subnets_json" 2>/dev/null || true)
    if [[ -n $line ]]; then
      NODE_CIDR=${line%% *}
      pools=${line#* }
      if [[ $pools == "$line" ]]; then pools=""; fi
      NODE_POOLS=$pools
      ok "Subnet ${SUBNET}: ${NODE_CIDR}${NODE_POOLS:+, IPAM pool ${NODE_POOLS}}"
    fi
  fi
  if [[ -z $NODE_POOLS ]]; then
    info "No Nutanix IPAM pool found for ${SUBNET} (external DHCP?). IP checks will use the CIDR only."
    ask NODE_CIDR "Node subnet CIDR, for IP validation (leave blank to skip)" optional
    if [[ -n $NODE_CIDR ]] && ! v_cidr "$NODE_CIDR"; then NODE_CIDR=""; fi
  fi

  if ((PC_API_OK)); then
    mapfile -t img_all < <(pc_api POST /api/nutanix/v3/images/list '{"kind":"image","length":500}' 2>/dev/null \
      | jq -r '.entities[].status.name' | sort -u || true)
    mapfile -t img_list < <(printf '%s\n' "${img_all[@]}" | grep -F -- "$K8S_VERSION_HINT" || true)
    if ((${#img_list[@]} == 0 && ${#img_all[@]} > 0)); then
      warn "No image name contains Kubernetes ${K8S_VERSION_HINT}; the NKP preflight check expects the version in the name. Showing all images."
      img_list=("${img_all[@]}")
    fi
  fi
  pick VM_IMAGE "Node OS image (Nutanix pre-built NKP image, not renamed)" img_list
  [[ $VM_IMAGE == *"$K8S_VERSION_HINT"* ]] || warn "'${VM_IMAGE}' does not contain ${K8S_VERSION_HINT}; preflight may reject it."

  if ((PC_API_OK)); then
    # shellcheck disable=SC2016
    mapfile -t sc_list < <(pc_api GET '/api/clustermgmt/v4.0/config/storage-containers?$limit=100' 2>/dev/null \
      | jq -r --arg c "$NUTANIX_CLUSTER" '.data[]? | select((.clusterName // $c) == $c) | .name
               | select(. != "NutanixManagementShare" and . != "SelfServiceContainer")' | sort -u || true)
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
VMS_FILE=""

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

load_vms() { # every VM in Prism Central (paged) as one JSON array in VMS_FILE
  [[ -z $VMS_FILE ]] || return 0
  local dir offset=0 total=1 n page=0
  dir=$(mktemp -d)
  while ((offset < total)); do
    page=$((page + 1))
    pc_api POST /api/nutanix/v3/vms/list "{\"kind\":\"vm\",\"length\":250,\"offset\":${offset}}" >"${dir}/${page}.json" 2>/dev/null \
      || { rm -rf "$dir"; return 1; }
    total=$(jq -r '.metadata.total_matches // 0' "${dir}/${page}.json")
    n=$(jq -r '.entities | length' "${dir}/${page}.json")
    ((n > 0)) || break
    offset=$((offset + n))
  done
  VMS_FILE="${WORKDIR}/pc-vms.json"
  jq -s '[.[].entities[]?]' "$dir"/*.json >"$VMS_FILE"
  rm -rf "$dir"
}

used_ips() { # subnet_json -> addresses in use: VM NICs, Prism Element/Central, hosts, gateway, DHCP server
  if [[ -n $VMS_FILE ]]; then
    jq -r '.[] | .status.resources.nic_list[]? | .ip_endpoint_list[]? | .ip // empty' "$VMS_FILE" 2>/dev/null || true
  fi
  jq -r '.entities[]? | (.status.resources.network // {}), (.spec.resources.network // {})
         | .external_ip, .external_data_services_ip | strings' <<<"$CLUSTERS_JSON" 2>/dev/null || true
  if [[ $PC_HOST =~ ^[0-9.]+$ ]]; then printf '%s\n' "$PC_HOST"; fi
  pc_api POST /api/nutanix/v3/hosts/list '{"kind":"host","length":500}' 2>/dev/null \
    | jq -r '.entities[]? | .status.resources | (.hypervisor.ip, .controller_vm.ip, .ipmi.ip) | strings' 2>/dev/null || true
  jq -r '.spec.resources.ip_config | (.default_gateway_ip, .dhcp_server_address.ip) | strings' <<<"$1" 2>/dev/null || true
}

ip_select() { # pools(a-b,...) used_file max min node_reserve -> KEY=value plan; exit 1 if no free run of min addresses
  python3 - "$@" <<'PY'
import ipaddress, sys
pools_s, used_f = sys.argv[1], sys.argv[2]
mx, mn, keep = (int(x) for x in sys.argv[3:6])
A = ipaddress.ip_address
pools = []
for p in pools_s.split(","):
    if p.strip():
        lo, hi = (int(A(x.strip())) for x in p.split("-", 1))
        pools.append((lo, hi))
used = set()
for line in open(used_f):
    try:
        used.add(int(A(line.strip())))
    except ValueError:
        pass
runs = []  # maximal runs of free addresses inside the pools
for lo, hi in pools:
    start = None
    for ip in range(lo, hi + 1):
        if ip in used:
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
    sys.exit(1)
lo, hi = max(runs, key=lambda r: r[1])  # the run closest to the end of the pool
n = min(mx, hi - lo + 1, free - keep)
if n < mn:
    sys.exit(1)
b = list(range(hi - n + 1, hi + 1))
s = lambda i: str(A(i))
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
print(f"IP_PLAN_COUNT={n}")
print(f"IP_PLAN_BLOCK={s(b[0])}-{s(b[-1])}")
print("IP_PLAN_NEW_POOLS=" + ",".join(f"{s(x)}-{s(y)}" for x, y in new))
print(f"MGMT_CONTROLPLANE_IP={s(b[0])}")
print(f"WL_CONTROLPLANE_IP={s(b[1])}")
print(f"MGMT_LB_RANGE={s(b[2])}-{s(b[1 + half])}")
print(f"WL_LB_RANGE={s(b[2 + half])}-{s(b[1 + 2 * half])}")
PY
}

range_responders() { # a-b -> the addresses in it that answer ping
  python3 -c 'import ipaddress as i, sys
lo, hi = (int(i.ip_address(x)) for x in sys.argv[1].split("-"))
print("\n".join(str(i.ip_address(n)) for n in range(lo, hi + 1)))' "$1" \
    | xargs -P 32 -I{} sh -c 'ping -c1 -W1 {} >/dev/null 2>&1 && echo {}' | sort -V || true
}

ranges_to_pools() { jq -nc --arg r "$1" '[$r | split(",")[] | select(length > 0) | {range: sub("-"; " ")}]'; }

lab_dns_ip() { # first IPv4 of the VM named LAB_DNS_VM (exact match preferred, case-insensitive)
  [[ -n $VMS_FILE ]] || return 0
  jq -r --arg n "${LAB_DNS_VM,,}" '
      [.[] | ((.status.name // .spec.name // "") | ascii_downcase) as $vm | select($vm | contains($n))
       | {exact: ($vm == $n), ip: ([.status.resources.nic_list[]? | .ip_endpoint_list[]? | .ip // empty
                                   | select(test("^[0-9]+([.][0-9]+){3}$"))][0])}
       | select(.ip)] | sort_by(.exact | not) | .[0].ip // empty' "$VMS_FILE" 2>/dev/null || true
}

dns_answers() { # server name -> 0 if the server returns an address for name
  python3 - "$1" "$2" <<'PY'
import random, socket, struct, sys
server, name = sys.argv[1:3]
qid = random.randint(0, 65535)
query = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
query += b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
query += struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
try:
    s.sendto(query, (server, 53))
    data = s.recv(4096)
except OSError:
    sys.exit(1)
rid, flags, _, answers = struct.unpack(">HHHH", data[:8])
sys.exit(0 if rid == qid and flags & 0x000F == 0 and answers > 0 else 1)
PY
}

subnet_update() { # JSON body -> PUT it to SUBNET_UUID and wait for the Prism Central task
  local out code task status i
  out=$(pc_curl -X PUT -H 'Content-Type: application/json' --data "$1" -w '\n%{http_code}' \
    "${NUTANIX_ENDPOINT}/api/nutanix/v3/subnets/${SUBNET_UUID}" 2>&1) || true
  code=${out##*$'\n'} out=${out%$'\n'*}
  if [[ $code != 2?? ]]; then
    err "Prism Central rejected the subnet update (HTTP ${code}): $(jq -r '[.message_list[]?.message] | join("; ")' <<<"$out" 2>/dev/null || head -c 300 <<<"$out")"
    return 1
  fi
  task=$(jq -r '.status.execution_context.task_uuid // empty' <<<"$out" 2>/dev/null || true)
  [[ -n $task ]] || return 0
  for ((i = 0; i < 90; i++)); do
    status=$(pc_api GET "/api/nutanix/v3/tasks/${task}" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
    case $status in
      SUCCEEDED)     return 0 ;;
      FAILED|ABORTED) err "Subnet update task ${task} ${status}."; return 1 ;;
    esac
    sleep 2
  done
  err "Subnet update task ${task} did not finish within 3 minutes."
  return 1
}

subnet_pools() { jq -r '[.spec.resources.ip_config.pool_list[]?.range | gsub(" +"; "-")] | join(",")' <<<"$1"; }

lab_network() { # management run, between q_inventory and q_network
  step "Lab network: addresses for NKP and DNS"
  local f subnet_json pools used_file plan="" responders="" try k v dns_ip="" dhcp_new=null body now
  local IP_PLAN_COUNT IP_PLAN_BLOCK IP_PLAN_NEW_POOLS MGMT_CONTROLPLANE_IP WL_CONTROLPLANE_IP MGMT_LB_RANGE WL_LB_RANGE
  local IP_PLAN_SUBNET=$SUBNET IP_PLAN_SUBNET_UUID=$SUBNET_UUID IP_PLAN_ORIGINAL_POOLS IP_PLAN_ORIGINAL_DHCP IP_PLAN_DNS="" IP_PLAN_DOMAIN=""
  f=$(ip_plan_file)
  if ((NO_IP_PLAN)); then info "--no-ip-plan: the subnet's IPAM pool and DHCP options stay as they are."; return 0; fi
  if ((!PC_API_OK)) || [[ -z $SUBNET_UUID ]]; then warn "Prism Central API not available; skipping the IP plan."; return 0; fi
  if [[ -f $f && $(ip_plan_get IP_PLAN_SUBNET_UUID) == "$SUBNET_UUID" ]] \
     && ! ipcalc range_overlaps "$(ip_plan_get IP_PLAN_BLOCK)" "$NODE_POOLS"; then
    ok "Reusing ${f}: $(ip_plan_get IP_PLAN_BLOCK) is already outside the IPAM pool of ${SUBNET}"
    return 0
  fi
  subnet_json=$(pc_api GET "/api/nutanix/v3/subnets/${SUBNET_UUID}" 2>/dev/null) \
    || { warn "Could not read subnet ${SUBNET}; skipping the IP plan."; return 0; }
  pools=$(subnet_pools "$subnet_json")
  if [[ -z $pools ]]; then warn "${SUBNET} has no IPAM pool; nothing to reserve. Enter the addresses yourself."; return 0; fi
  load_vms || warn "Could not list the VMs; only ping will detect used addresses."
  used_file=$(mktemp)
  used_ips "$subnet_json" >"$used_file"
  for try in 1 2 3 4 5; do
    plan=$(ip_select "$pools" "$used_file" "$IP_PLAN_MAX" "$IP_PLAN_MIN" "$IP_PLAN_NODE_RESERVE") || {
      rm -f "$used_file"
      die "The IPAM pool ${pools} of ${SUBNET} has no run of ${IP_PLAN_MIN} free addresses (keeping ${IP_PLAN_NODE_RESERVE} for nodes). Free some, or rerun with --no-ip-plan."
    }
    responders=$(range_responders "$(sed -n 's/^IP_PLAN_BLOCK=//p' <<<"$plan")")
    [[ -n $responders ]] || break
    warn "Attempt ${try}: addresses answering ping in the candidate block: ${responders//$'\n'/ }"
    printf '%s\n' "$responders" >>"$used_file"
  done
  rm -f "$used_file"
  [[ -z $responders ]] || die "Could not find a block of addresses that nobody answers on. Rerun with --no-ip-plan."
  while IFS='=' read -r k v; do printf -v "$k" '%s' "$v"; done <<<"$plan"

  dns_ip=$(lab_dns_ip)
  if [[ -z $dns_ip ]]; then
    warn "No VM named '${LAB_DNS_VM}' with an IPv4 address; the subnet's DNS settings stay unchanged."
  elif ! dns_answers "$dns_ip" "$LAB_DOMAIN"; then
    warn "${LAB_DNS_VM} (${dns_ip}) does not resolve ${LAB_DOMAIN}; the subnet's DNS settings stay unchanged."
  else
    ok "${LAB_DNS_VM} (${dns_ip}) resolves ${LAB_DOMAIN}"
    IP_PLAN_DNS=$dns_ip IP_PLAN_DOMAIN=$LAB_DOMAIN
    dhcp_new=$(jq -nc --arg ip "$dns_ip" --arg d "$LAB_DOMAIN" '{domain_name_server_list: [$ip], domain_name: $d, domain_search_list: [$d]}')
  fi

  row "IPAM pool of ${SUBNET}" "$pools"
  row "Reserve for NKP" "${IP_PLAN_BLOCK} (${IP_PLAN_COUNT} addresses)"
  row "New IPAM pool" "${IP_PLAN_NEW_POOLS:-none}"
  row "Management cluster" "API ${MGMT_CONTROLPLANE_IP}, load balancer ${MGMT_LB_RANGE}"
  row "Workload cluster" "API ${WL_CONTROLPLANE_IP}, load balancer ${WL_LB_RANGE}"
  if [[ -n $IP_PLAN_DNS ]]; then row "DHCP DNS server / domain" "${IP_PLAN_DNS} / ${IP_PLAN_DOMAIN}"; fi
  if ! ask_yn "Apply this to subnet ${SUBNET} in Prism Central (undone by --destroy)?" Y; then
    info "Subnet unchanged. Enter addresses outside the IPAM pool yourself."
    return 0
  fi

  IP_PLAN_ORIGINAL_POOLS=$(jq -c '.spec.resources.ip_config.pool_list // []' <<<"$subnet_json")
  IP_PLAN_ORIGINAL_DHCP=$(jq -c '.spec.resources.ip_config.dhcp_options // null' <<<"$subnet_json")
  (
    umask 077
    echo "# NKP IP plan written $(date -Is). ${SCRIPT_PATH} --destroy restores the original pool and DHCP options."
    for k in IP_PLAN_SUBNET IP_PLAN_SUBNET_UUID IP_PLAN_ORIGINAL_POOLS IP_PLAN_ORIGINAL_DHCP IP_PLAN_NEW_POOLS IP_PLAN_BLOCK \
             IP_PLAN_COUNT IP_PLAN_DNS IP_PLAN_DOMAIN MGMT_CONTROLPLANE_IP WL_CONTROLPLANE_IP MGMT_LB_RANGE WL_LB_RANGE; do
      printf '%s=%q\n' "$k" "${!k}"
    done
  ) >"$f"
  chmod 600 "$f"
  body=$(jq -c --argjson pools "$(ranges_to_pools "$IP_PLAN_NEW_POOLS")" --argjson dhcp "$dhcp_new" '
      {api_version: (.api_version // "3.1"), metadata: .metadata,
       spec: (.spec | .resources.ip_config.pool_list = $pools
              | if $dhcp then .resources.ip_config.dhcp_options = ((.resources.ip_config.dhcp_options // {}) + $dhcp) else . end)}' \
    <<<"$subnet_json")
  if ! subnet_update "$body"; then
    rm -f "$f"
    die "The subnet was not changed. Rerun, or use --no-ip-plan and enter addresses yourself."
  fi
  now=$(subnet_pools "$(pc_api GET "/api/nutanix/v3/subnets/${SUBNET_UUID}" 2>/dev/null || true)" 2>/dev/null || true)
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

q_sizing() {
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
  if [[ $SIZING == starter && ${VM_IMAGE,,} != *rocky* ]]; then
    warn "The Starter license supports Rocky Linux images only; '${VM_IMAGE}' needs Pro or Ultimate."
  fi
}

bundle_candidates() { # -> container-images directories of extracted air-gapped bundles for NKP_MINOR, newest first
  local d
  if [[ -n $PACKAGE && $(basename "$PACKAGE") == nkp-air-gapped-bundle_* ]]; then
    d="${HOME}/nkp-dist/$(basename "$PACKAGE" .tar.gz)"
    find "$d" -maxdepth 3 -type d -name container-images 2>/dev/null || true
  fi
  find "${HOME}/nkp-dist" -maxdepth 3 -type d -path "*/nkp-air-gapped-bundle_v${NKP_MINOR}.*/container-images" 2>/dev/null \
    | sort -r || true
}

bundle_files() { # container-images dir -> comma-separated tars for --bundle; exit 1 with the reason when incomplete
  local dir=$1 f name out=() ver_re="-v?${NKP_MINOR//./\\.}\.[0-9]+"
  for name in konvoy-image-bundle kommander-image-bundle nkp-release-specs nutanix-product-catalog; do
    f=$(find "$dir" -maxdepth 1 -type f -name "${name}-*.tar" 2>/dev/null | sort | awk 'END {print}')
    if [[ -z $f ]]; then
      if [[ $name == k* ]]; then echo "      ${dir} has no ${name}-*.tar." >&2; return 1; fi
      continue
    fi
    if [[ ! $(basename "$f") =~ $ver_re ]]; then
      echo "      $(basename "$f") is not an NKP ${NKP_MINOR} bundle." >&2; return 1
    fi
    out+=("$f")
  done
  if [[ ${USE_NDK_BUNDLE:-N} == Y ]]; then
    f=$(find "$dir" -maxdepth 1 -type f -name 'ndk-*.tar' 2>/dev/null | sort | awk 'END {print}')
    [[ -n $f ]] || { echo "      ${dir} has no ndk-*.tar; copy the NDK bundle there or answer No to NDK." >&2; return 1; }
    out+=("$f")
  fi
  local IFS=,
  printf '%s' "${out[*]}"
}

v_bundle_dir() {
  [[ -d $1 ]] || { echo "      Not a directory: $1" >&2; return 1; }
  bundle_files "$1" >/dev/null
}

q_bundle() { # management cluster: seed its internal registry (NCR) from the air-gapped bundle
  BUNDLE_ARGS=() BUNDLE_COUNT=0
  if [[ -n $BUNDLE_DIR_ARG ]]; then BUNDLE_DIR=$BUNDLE_DIR_ARG USE_BUNDLE=Y; fi
  if [[ ${USE_BUNDLE:-} == N ]]; then info "Image bundle: not used (USE_BUNDLE=N); images come from the internet."; return 0; fi
  if [[ -z ${BUNDLE_DIR:-} || ! -d $BUNDLE_DIR ]]; then BUNDLE_DIR=$(bundle_candidates | awk 'NR == 1'); fi
  if [[ -z $BUNDLE_DIR && ${USE_BUNDLE:-} != Y ]]; then
    info "No extracted air-gapped bundle under ${HOME}/nkp-dist: images come from the internet (Docker Hub)."
    info "For a local registry, download nkp-air-gapped-bundle_v${NKP_MINOR}.x and rerun with --package (or --bundle-dir)."
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
  info "NKP pushes the bundle's images into ${CLUSTER_NAME}'s internal registry (Harbor, namespace ncr-system),"
  info "and workload clusters can then pull from it instead of Docker Hub. Images outside the bundle still come from the internet."
  if ! ask_yn "Seed the internal registry from the bundle?" "${USE_BUNDLE:-Y}"; then USE_BUNDLE=N; return 0; fi
  USE_BUNDLE=Y
  if ask_yn "Also push the NDK catalog bundle (ndk-*.tar; only if you will deploy NDK)?" "${USE_NDK_BUNDLE:-N}"; then
    USE_NDK_BUNDLE=Y
  else
    USE_NDK_BUNDLE=N
  fi
  ask BUNDLE_DIR "Bundle directory (container-images)" v_bundle_dir
  BUNDLE_DIR=$(readlink -f "$BUNDLE_DIR")
  local files f parts names=()
  files=$(bundle_files "$BUNDLE_DIR")
  IFS=, read -r -a parts <<<"$files"
  for f in "${parts[@]}"; do names+=("$(basename "$f")"); done
  BUNDLE_ARGS=(--bundle="$files") BUNDLE_COUNT=${#parts[@]}
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

pc_ntp_servers() { # from CLUSTERS_JSON: Prism Central's NTP list, else the node cluster's
  jq -r --arg c "$NUTANIX_CLUSTER" '
      def ntp: [.. | .ntp_server_ip_list? // empty | .[]?
                | if type == "string" then . else (.ipv4.value? // .fqdn.value? // .value? // empty) end] | unique;
      ([.entities[]? | select((.status.resources.config.service_list // []) | index("PRISM_CENTRAL")) | ntp] | add // []) as $pc
      | ([.entities[]? | select(.status.name == $c) | ntp] | add // []) as $pe
      | (if ($pc | length) > 0 then $pc else $pe end) | join(",")' <<<"$CLUSTERS_JSON" 2>/dev/null || true
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
  if [[ -z ${NTP_SERVERS:-} && -n ${CLUSTERS_JSON:-} ]]; then
    NTP_SERVERS=$(pc_ntp_servers)
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
  local nodes=$1 vcpus=$2 mem=$3 disk=$(($1 * NODE_DISK_GIB)) line nhosts="" cores=0 hmem=0 vm_cpu=0 vm_mem=0 cvm free usable sc cap
  local registry=""
  if ((${#BUNDLE_ARGS[@]})); then disk=$((disk + HARBOR_DISK_GIB)) registry=" (incl. ${HARBOR_DISK_GIB} GiB for the internal registry)"; fi
  if ((!PC_API_OK)) || [[ -z ${PE_UUID:-} ]]; then warn "Prism Central API not available; skipping the capacity check."; return 0; fi
  line=$(pc_api GET "/api/clustermgmt/v4.0/config/clusters/${PE_UUID}/hosts" 2>/dev/null \
    | jq -r '[.data[]?] | "\(length) \(map(.numberOfCpuCores // 0) | add // 0) \(map(.memorySizeBytes // 0) | add // 0 | ./1073741824 | floor)"' \
    2>/dev/null || true)
  read -r nhosts cores hmem <<<"$line"
  if [[ -z $nhosts ]] || ((nhosts == 0 || hmem == 0)); then
    warn "Could not read the hosts of ${NUTANIX_CLUSTER}; skipping the capacity check."
    return 0
  fi
  if load_vms; then
    line=$(jq -r --arg u "$PE_UUID" '
        [.[] | select(.status.cluster_reference.uuid == $u and .status.resources.power_state == "ON") | .status.resources]
        | "\(map((.num_sockets // 1) * (.num_vcpus_per_socket // 1)) | add // 0) \(map(.memory_size_mib // 0) | add // 0 | ./1024 | floor)"' \
      "$VMS_FILE" 2>/dev/null || true)
    read -r vm_cpu vm_mem <<<"$line"
  else
    warn "Could not list the VMs; assuming the cluster is empty."
  fi
  cvm=$((nhosts * CVM_RESERVE_GIB))
  free=$((hmem - ${vm_mem:-0} - cvm))
  usable=$((free * 90 / 100))
  row "Hosts" "${nhosts}: ${cores} cores, ${hmem} GiB memory"
  row "Running VMs" "${vm_cpu:-0} vCPU, ${vm_mem:-0} GiB (CVMs about ${cvm} GiB)"
  row "NKP adds" "${nodes} VMs: ${vcpus} vCPU, ${mem} GiB memory, ${disk} GiB disk${registry}"
  if ((cores > 0 && ${vm_cpu:-0} + vcpus > cores * 4)); then
    warn "vCPU overcommit would be $(((${vm_cpu:-0} + vcpus) / cores)):1, above 4:1. Expect slow platform applications."
  fi
  # shellcheck disable=SC2016
  sc=$(pc_api GET '/api/clustermgmt/v4.0/config/storage-containers?$limit=100' 2>/dev/null \
    | jq -c --arg n "$STORAGE_CONTAINER_NAME" --arg u "$PE_UUID" \
        '[.data[]? | select(.name == $n and ((.clusterExtId // $u) == $u))][0] // empty' 2>/dev/null || true)
  if [[ -n $sc ]]; then
    cap=$(storage_free_gib "$sc")
    if [[ -n $cap ]] && ((disk > cap)); then
      warn "Storage container ${STORAGE_CONTAINER_NAME} has about ${cap} GiB free; NKP takes up to ${disk} GiB${registry} (thin provisioned)."
    elif [[ -n $cap ]]; then
      ok "Storage: ${disk} GiB${registry}, about ${cap} GiB free in ${STORAGE_CONTAINER_NAME}"
    fi
  fi
  if ((mem > usable)); then
    warn "Not enough memory: NKP needs ${mem} GiB, about ${usable} GiB is free after the CVMs and a 10% margin."
    ask_yn "Continue anyway?" N || die "Choose a smaller size (Starter) or free memory on ${NUTANIX_CLUSTER}, then rerun."
  else
    ok "Memory: ${mem} GiB needed, about ${usable} GiB free"
  fi
}

storage_free_gib() { # storage container JSON (v4) -> free GiB, from its stats when available, else its capacity
  local id stats used max
  id=$(jq -r '.containerExtId // .extId // empty' <<<"$1")
  max=$(jq -r '.maxCapacityBytes // empty' <<<"$1")
  [[ -n $id && -n $max ]] || return 0
  stats=$(pc_api GET "/api/clustermgmt/v4.0/stats/storage-containers/${id}?\$startTime=$(date -u -d '-1 hour' +%FT%TZ)&\$endTime=$(date -u +%FT%TZ)&\$statType=LAST&\$samplingInterval=3600" 2>/dev/null || true)
  used=$(jq -r '[.data.storageUsageBytes[]?.value] | last // empty' <<<"$stats" 2>/dev/null || true)
  jq -nr --argjson m "$max" --argjson u "${used:-0}" '($m - $u) / 1073741824 | floor'
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
    row "Images" "bundle (${BUNDLE_COUNT} files from ${BUNDLE_DIR}) -> internal registry"
  elif ((${#REGISTRY_MIRROR_ARGS[@]})); then
    row "Images" "${MGMT_CLUSTER_NAME} internal registry ${NCR_URL} (${NCR_AUTH})"
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
      info "Platform apps keep retrying on their own. Check again with: ${SCRIPT_PATH} --status"
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
  out=$("${k[@]}" -n kommander get helmreleases 2>&1 | awk 'NR == 1 || $0 !~ /True/' || true)
  if [[ $(wc -l <<<"$out") -le 1 ]]; then ok "All platform applications are ready"
  else info "Platform applications not ready:"; printf '%s\n' "$out" >&2; fi
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
  if url=$(ncr_url "$kcfg"); then
    info "Internal registry: ${url} (user admin; password: $(ncr_password_cmd "$kcfg"))"
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
      if url=$(ncr_url "$mk"); then
        seeded=""
        if [[ ${USE_BUNDLE:-} == Y ]]; then seeded=", seeded from the bundle"; fi
        printf '  %-20s %s\n' "Internal registry" "${url} (user admin${seeded})"
        printf '    password: %s\n' "$(ncr_password_cmd "$mk")"
      fi
    fi
    if [[ -f ${WORKDIR}/nkp-workload.env ]]; then
      # shellcheck disable=SC1090,SC1091
      . "${WORKDIR}/nkp-workload.env"
      printf '\nWorkload cluster       %s (workspace %s)\n' "$CLUSTER_NAME" "$WORKSPACE_NAMESPACE"
      printf '  %-20s %s\n' "API endpoint" "https://${CONTROLPLANE_IP}:6443" "Load balancer range" "$SERVICE_LB_IP_RANGE" \
        "Kubeconfig" "${WORKDIR}/${CLUSTER_NAME}/${CLUSTER_NAME}.conf"
      if [[ ${USE_MGMT_REGISTRY:-} == Y ]]; then
        printf '  %-20s %s\n' "Images" "from ${m}'s internal registry${url:+ (${url})}"
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
  Delete the whole lab:  ${SCRIPT_PATH} --destroy
EOF
  ) >"$f.tmp" 2>/dev/null || true
  umask "$mask"
  mv -f "$f.tmp" "$f"
  chmod 600 "$f"
}

helmreleases_not_ready() { # kubeconfig namespace -> prints HelmReleases that are not Ready; exit 1 if none exist yet
  local out
  out=$(kubectl --kubeconfig "$1" -n "$2" get helmreleases --no-headers 2>/dev/null || true)
  [[ -n $out ]] || return 1
  awk '$3 != "True"' <<<"$out"
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
  local kcfg=$1 cluster=$2 hr_ns=$3 mgmt=$4 attempt starved md md_ns md_name replicas ts failed hr
  for attempt in 1 2; do
    starved=$(kubectl --kubeconfig "$kcfg" get pods -A --field-selector=status.phase=Pending -o json 2>/dev/null \
      | jq -r '.items[] | select(any(.status.conditions[]?; .type == "PodScheduled" and .status == "False"
                 and ((.message // "") | test("Insufficient (cpu|memory)")))) | "\(.metadata.namespace)/\(.metadata.name)"' \
      2>/dev/null || true)
    if [[ -n $starved ]]; then
      warn "Pods that cannot be scheduled for lack of CPU or memory: ${starved//$'\n'/ }"
      md=$(kubectl --kubeconfig "$mgmt" get machinedeployments -A -l "cluster.x-k8s.io/cluster-name=${cluster}" -o json 2>/dev/null \
        | jq -r '[.items[] | select((.metadata.labels["topology.cluster.x-k8s.io/deployment-name"] // .metadata.name) | test("md-0"))][0]
                 // empty | "\(.metadata.namespace) \(.metadata.name) \(.spec.replicas)"' 2>/dev/null || true)
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
    failed=$(helmreleases_not_ready "$kcfg" "$hr_ns" | awk '{print $1}' || true)
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for hr in $failed; do
      kubectl --kubeconfig "$kcfg" -n "$hr_ns" annotate --overwrite "helmreleases.helm.toolkit.fluxcd.io/${hr}" \
        "reconcile.fluxcd.io/requestedAt=${ts}" "reconcile.fluxcd.io/resetAt=${ts}" "reconcile.fluxcd.io/forceAt=${ts}" >/dev/null 2>&1 || true
    done
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
  BUNDLE_ARGS=() REGISTRY_MIRROR_ARGS=() NCR_URL="" NCR_AUTH=""
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
  q_sizing
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
  BUNDLE_ARGS=() REGISTRY_MIRROR_ARGS=() NCR_URL="" NCR_AUTH=""
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
  ask_yn "Create ${CLUSTER_NAME} and then ${WL_CLUSTER_NAME} now, without further questions (about 90 minutes)?" Y \
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
  local f="${WORKDIR}/nkp-install.env" json kv
  [[ -f $f ]] || die "No management cluster answers at ${f}. Create the management cluster first, or pass --workdir."
  # shellcheck disable=SC1090
  . "$f"
  MGMT_CLUSTER_NAME=$CLUSTER_NAME MGMT_USE_BUNDLE=${USE_BUNDLE:-N}
  MGMT_KCFG="${WORKDIR}/${MGMT_CLUSTER_NAME}/${MGMT_CLUSTER_NAME}.conf"
  [[ -f $MGMT_KCFG ]] || die "No kubeconfig for ${MGMT_CLUSTER_NAME} at ${MGMT_KCFG}."
  MGMT_K=(kubectl --kubeconfig "$MGMT_KCFG")
  json=$("${MGMT_K[@]}" get clusters.cluster.x-k8s.io -A -o json 2>/dev/null) \
    || die "Cannot list Cluster API clusters on ${MGMT_CLUSTER_NAME} with ${MGMT_KCFG}. Is it up? Try: ${SCRIPT_PATH} --status"
  ok "Management cluster ${MGMT_CLUSTER_NAME} is reachable"
  kv=$("${MGMT_K[@]}" get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
  if [[ $kv =~ ^v?([0-9]+\.[0-9]+) ]]; then
    K8S_VERSION_HINT=${BASH_REMATCH[1]}
    info "${MGMT_CLUSTER_NAME} runs Kubernetes ${kv}; the workload node image should be built for ${K8S_VERSION_HINT}."
  fi
  RESERVED_RANGES=$(jq -r '
      [ .items[]?
        | (.spec.controlPlaneEndpoint.host // empty | select(test("^[0-9.]+$")) | "\(.)-\(.)"),
          (.. | objects | select(has("addressRanges")) | .addressRanges[]? | select(.start and .end) | "\(.start)-\(.end)") ]
      | unique | join(",")' <<<"$json" 2>/dev/null || true)
  if [[ -n ${CONTROLPLANE_IP:-} ]]; then RESERVED_RANGES+="${RESERVED_RANGES:+,}${CONTROLPLANE_IP}-${CONTROLPLANE_IP}"; fi
  if [[ -n ${SERVICE_LB_IP_RANGE:-} ]]; then RESERVED_RANGES+="${RESERVED_RANGES:+,}${SERVICE_LB_IP_RANGE}"; fi
  RESERVED_RANGES=$(tr ',' '\n' <<<"$RESERVED_RANGES" | awk 'NF && !seen[$0]++' | paste -sd, - || true)
  [[ -z $RESERVED_RANGES ]] || info "Addresses already used by NKP clusters: ${RESERVED_RANGES}"
}

ncr_url() { # management kubeconfig -> https://<ingress address>:5000 when the internal registry (ncr-system) exists
  local k=(kubectl --kubeconfig "$1") host
  "${k[@]}" -n ncr-system get secret harbor-admin-password >/dev/null 2>&1 || return 1
  host=$("${k[@]}" -n kommander get kommanderclusters -l kommander.d2iq.io/host=true \
    -o jsonpath='{.items[0].status.ingress.address}' 2>/dev/null || true)
  [[ -n $host ]] || return 1
  printf 'https://%s:%s' "$host" "$NCR_PORT"
}

ncr_password_cmd() { # management kubeconfig -> the command that prints the Harbor admin password
  printf "kubectl --kubeconfig %s -n ncr-system get secret harbor-admin-password -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d" "$1"
}

harbor_api() { # METHOD PATH [JSON]: Harbor API of the internal registry as admin
  local extra=()
  if [[ -n ${3-} ]]; then extra=(-H 'Content-Type: application/json' --data "$3"); fi
  printf 'user = "admin:%s"\n' "$(cfg_escape "$NCR_ADMIN_PASSWORD")" \
    | curl -K - -sS --fail --max-time 30 --cacert "$NCR_CACERT" -H 'Accept: application/json' \
        -X "$1" "${extra[@]}" "${NCR_URL}/api/v2.0$2"
}

ncr_robot() { # name -> "user secret" of a new pull-only robot account on every project; replaces one with that name
  local name=$1 id body out
  while read -r id; do
    [[ -z $id ]] || harbor_api DELETE "/robots/${id}" >/dev/null || true
  done < <(harbor_api GET '/robots?page_size=100' 2>/dev/null \
    | jq -r --arg n "$name" '.[]? | select(.name == $n or (.name | endswith("$" + $n))) | .id' 2>/dev/null || true)
  body=$(jq -nc --arg n "$name" --arg d "Pull-only access for NKP workload cluster ${CLUSTER_NAME}" \
    '{name: $n, description: $d, level: "system", duration: -1, disable: false,
      permissions: [{kind: "project", namespace: "*", access: [{resource: "repository", action: "pull"}]}]}')
  out=$(harbor_api POST /robots "$body" 2>/dev/null) || return 1
  jq -er '"\(.name) \(.secret)"' <<<"$out" 2>/dev/null
}

q_mgmt_registry() { # workload cluster: pull images through the management cluster's internal registry
  REGISTRY_MIRROR_ARGS=() NCR_URL="" NCR_AUTH=""
  local def=${USE_MGMT_REGISTRY:-$MGMT_USE_BUNDLE} ca projects robot user="" pass=""
  [[ $def == Y ]] || def=N
  if ! NCR_URL=$(ncr_url "$MGMT_KCFG"); then
    NCR_URL=""
    info "Images: ${MGMT_CLUSTER_NAME} has no internal registry (ncr-system); ${CLUSTER_NAME} pulls from the internet."
    USE_MGMT_REGISTRY=N
    return 0
  fi
  step "Images"
  if [[ $(nkp create cluster nutanix --help 2>&1 || true) != *--registry-mirror-url* ]]; then
    warn "This nkp CLI has no --registry-mirror-url option; ${CLUSTER_NAME} pulls from the internet."
    USE_MGMT_REGISTRY=N NCR_URL=""
    return 0
  fi
  if [[ $MGMT_USE_BUNDLE != Y ]]; then
    info "${MGMT_CLUSTER_NAME} was not seeded from the bundle, so its internal registry may not hold the NKP images."
  fi
  if ! ask_yn "Pull ${CLUSTER_NAME}'s images from ${MGMT_CLUSTER_NAME}'s internal registry (${NCR_URL}) instead of Docker Hub?" "$def"; then
    USE_MGMT_REGISTRY=N NCR_URL=""
    return 0
  fi
  USE_MGMT_REGISTRY=Y
  ca=$("${MGMT_K[@]}" -n kommander get kommanderclusters -l kommander.d2iq.io/host=true \
    -o jsonpath='{.items[0].status.ingress.caBundle}' 2>/dev/null || true)
  if [[ -z $ca ]]; then
    ca=$("${MGMT_K[@]}" -n kommander get nkpclusters -l kommander.d2iq.io/host=true \
      -o jsonpath='{.items[0].kommanderCluster.status.ingress.caBundle}' 2>/dev/null || true)
  fi
  [[ -n $ca ]] || die "Cannot read the ingress CA of ${MGMT_CLUSTER_NAME} (kommandercluster status). Try: ${SCRIPT_PATH} --status"
  NCR_CACERT="${CLUSTER_DIR}/ncr-ca.pem"
  (umask 077 && base64 -d <<<"$ca" >"$NCR_CACERT") 2>/dev/null || die "The ingress CA of ${MGMT_CLUSTER_NAME} is not valid base64."
  chmod 600 "$NCR_CACERT"
  grep -q 'BEGIN CERTIFICATE' "$NCR_CACERT" || die "The ingress CA of ${MGMT_CLUSTER_NAME} is not a PEM certificate."
  if curl -sS -o /dev/null --max-time 15 --cacert "$NCR_CACERT" "${NCR_URL}/v2/" 2>/dev/null; then
    ok "${NCR_URL} answers and its certificate matches the CA (${NCR_CACERT})"
  else
    warn "${NCR_URL} does not answer from this host with that CA; the nodes may still reach it."
  fi

  NCR_ADMIN_PASSWORD=$("${MGMT_K[@]}" -n ncr-system get secret harbor-admin-password \
    -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -n $NCR_ADMIN_PASSWORD ]] || die "Cannot read the Harbor admin password from ${MGMT_CLUSTER_NAME} (ncr-system/harbor-admin-password)."
  if projects=$(harbor_api GET '/projects?page_size=100' 2>/dev/null) \
     && jq -e 'length > 0 and all(.[]; .metadata.public == "true")' <<<"$projects" >/dev/null 2>&1; then
    NCR_AUTH=anonymous
    ok "Every project in the internal registry is public; ${CLUSTER_NAME} pulls without credentials."
  elif [[ -n ${projects:-} ]] && robot=$(ncr_robot "nkp-${CLUSTER_NAME#nkp-}"); then
    read -r user pass <<<"$robot"
    NCR_AUTH="robot ${user}"
    ok "Created pull-only robot account ${user} for ${CLUSTER_NAME}"
  else
    warn "The Harbor API at ${NCR_URL} did not answer as expected; a robot account could not be created."
    if ! ask_yn "Let ${CLUSTER_NAME} pull with the Harbor admin account instead?" Y; then
      USE_MGMT_REGISTRY=N NCR_URL=""
      info "${CLUSTER_NAME} pulls its images from the internet."
      return 0
    fi
    user=admin pass=$NCR_ADMIN_PASSWORD NCR_AUTH=admin
  fi
  REGISTRY_MIRROR_ARGS=(--registry-mirror-url="$NCR_URL" --registry-mirror-cacert="$NCR_CACERT")
  if [[ $NCR_AUTH != anonymous ]]; then
    REGISTRY_MIRROR_ARGS+=(--registry-mirror-username="$user" --registry-mirror-password="$pass")
  fi
}

q_workspace() {
  step "Workspace"
  info "NKP attaches the workload cluster to this workspace on ${MGMT_CLUSTER_NAME}."
  local vals=() labels=() name ns ws="" i
  while IFS=$'\t' read -r name ns; do
    if [[ -n $ns ]]; then vals+=("$ns"); labels+=("${name}  (namespace ${ns})"); fi
  done < <("${MGMT_K[@]}" get workspaces.workspaces.kommander.mesosphere.io -o json 2>/dev/null \
    | jq -r '.items[] | [.metadata.name, (.spec.namespaceName // .status.namespaceRef.name // "")] | @tsv' || true)
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
    "${MGMT_K[@]}" apply -f - >/dev/null <<EOF || die "Could not create workspace ${ws}."
apiVersion: workspaces.kommander.mesosphere.io/v1alpha1
kind: Workspace
metadata:
  name: ${ws}
  annotations:
    kommander.mesosphere.io/display-name: ${ws}
spec:
  namespaceName: ${ws}
EOF
    WORKSPACE_NAMESPACE=$ws
    for ((i = 0; i < 30; i++)); do
      if "${MGMT_K[@]}" get namespace "$ws" >/dev/null 2>&1; then break; fi
      sleep 2
    done
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
  BUNDLE_ARGS=() REGISTRY_MIRROR_ARGS=() NCR_URL="" NCR_AUTH=""
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
  q_sizing
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
  local f subnet_json pools dhcp body
  f=$(ip_plan_file)
  if [[ ! -f $f ]]; then info "No IP plan in ${WORKDIR}; the subnet was not changed by this script."; return 0; fi
  SUBNET_UUID=$(ip_plan_get IP_PLAN_SUBNET_UUID)
  pools=$(ip_plan_get IP_PLAN_ORIGINAL_POOLS)
  dhcp=$(ip_plan_get IP_PLAN_ORIGINAL_DHCP)
  [[ -n $(ip_plan_get IP_PLAN_DNS) ]] || dhcp=keep
  step "Restoring subnet $(ip_plan_get IP_PLAN_SUBNET)"
  subnet_json=$(pc_api GET "/api/nutanix/v3/subnets/${SUBNET_UUID}" 2>/dev/null) \
    || die "Cannot read subnet ${SUBNET_UUID} from Prism Central; ${f} is kept so you can rerun --destroy."
  body=$(jq -c --argjson pools "${pools:-[]}" --arg dhcp "$dhcp" '
      {api_version: (.api_version // "3.1"), metadata: .metadata,
       spec: (.spec | .resources.ip_config.pool_list = $pools
              | if $dhcp == "keep" then .
                elif $dhcp == "null" then del(.resources.ip_config.dhcp_options)
                else .resources.ip_config.dhcp_options = ($dhcp | fromjson) end)}' <<<"$subnet_json")
  subnet_update "$body" || die "Restoring the subnet failed; ${f} is kept so you can rerun --destroy."
  ok "IPAM pool restored to $(jq -r '[.[].range | gsub(" +"; "-")] | join(",")' <<<"${pools:-[]}")"
}

pc_login_from_answers() { # TLS settings and password for Prism Central API calls outside the setup flow
  case ${TLS_MODE:-insecure} in
    trusted) PC_TLS_ARGS=() ;;
    cafile)  PC_TLS_ARGS=(--cacert "${CLUSTER_DIR}/prism-central-ca.pem") ;;
    *)       PC_TLS_ARGS=(-k) ;;
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
  local f="${WORKDIR}/nkp-install.env" kcfg json ns name mgmt_ns boot confirm archive reachable=0
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

  if [[ -f $kcfg ]] && json=$(kubectl --kubeconfig "$kcfg" get clusters.cluster.x-k8s.io -A -o json 2>/dev/null); then
    reachable=1
  fi
  if ((reachable)); then
    while read -r ns name; do
      [[ -n $name && $name != "$CLUSTER_NAME" ]] || continue
      step "Deleting workload cluster ${name} (namespace ${ns})"
      nkp delete cluster -c "$name" -n "$ns" --kubeconfig="$kcfg" >&2 || warn "nkp delete cluster ${name} reported an error."
      kubectl --kubeconfig "$kcfg" -n "$ns" wait --for=delete "clusters.cluster.x-k8s.io/${name}" --timeout=30m >&2 \
        || die "${name} is still being deleted. Rerun --destroy once it is gone."
    done < <(jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' <<<"$json")
    mgmt_ns=$(jq -r --arg n "$CLUSTER_NAME" '[.items[] | select(.metadata.name == $n) | .metadata.namespace][0] // "default"' <<<"$json")

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
  for f in nkp-ip-plan.env nkp-install.env nkp-workload.env lab-summary.txt; do
    if [[ -f ${WORKDIR}/${f} ]]; then mv "${WORKDIR}/${f}" "$archive/"; fi
  done
  ok "Answers and IP plan moved to ${archive}"
}

main() {
  parse_args "$@"
  if ((INIT_CONFIG)); then init_config; return 0; fi
  if ((STATUS_ONLY)); then phase_status; return 0; fi
  if ((DESTROY)); then phase_destroy; return 0; fi
  if ((WORKLOAD)); then phase_workload; return 0; fi
  if ((DO_PREREQS)); then phase_prereqs; fi
  if ((!DO_SETUP)); then return 0; fi
  if ((LAB)); then phase_lab; else phase_setup; fi
  return 0
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
