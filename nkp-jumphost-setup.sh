#!/usr/bin/env bash
# NKP 2.18 management cluster setup for a Linux jump host (Nutanix AHV, non-air-gapped).
#
# Phase 1 installs prerequisites: cgroups v2 check, Docker 27.4.0, kubectl 1.35.x, and the
#         nkp CLI from the package you downloaded from the Nutanix Portal.
# Phase 2 asks for the Prism Central details interactively, validates them, runs the NKP
#         preflight checks, then runs `nkp create cluster nutanix --self-managed`.
#
# Usage:
#   ./nkp-jumphost-setup.sh [--package nkp_v2.18.x_linux_amd64.tar.gz] [options]
#
# Options:
#   --package PATH    NKP CLI package or air-gapped bundle (.tar.gz). Auto-detected in
#                     the current directory, $HOME and $HOME/Downloads when omitted.
#   --workdir DIR     Where answers, logs and the kubeconfig are kept (default: $HOME/nkp).
#   --prereqs-only    Run phase 1 only.
#   --skip-prereqs    Run phase 2 only.
#   --print-only      Do everything except the final cluster creation; print the command.
#   -h, --help        Show this help.
#
# Passwords are not saved in the answers file; to skip their prompts, export NUTANIX_PASSWORD
# and DOCKERHUB_PASSWORD before running. The preflight dry-run manifest (cluster-dryrun.yaml,
# mode 600) does contain the credentials, because nkp renders them into Kubernetes secrets. If the jump host reaches the internet through a proxy,
# configure apt/dnf for it and export HTTP_PROXY/HTTPS_PROXY/NO_PROXY before running.

# shellcheck disable=SC2034  # arrays handed to pick() by name look unused to shellcheck
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
ORIG_ARGS=("$@")

NKP_MINOR="2.18"
DOCKER_VERSION="27.4.0"
KUBECTL_MINOR="1.35"
KUBECTL_FALLBACK="v1.35.2"
K8S_VERSION_HINT="1.35"
DOCKERHUB_URL="https://registry-1.docker.io"

PACKAGE=""
WORKDIR="${HOME}/nkp"
DO_PREREQS=1
DO_SETUP=1
PRINT_ONLY=0

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
      --prereqs-only) DO_SETUP=0 ;;
      --skip-prereqs) DO_PREREQS=0 ;;
      --print-only)   PRINT_ONLY=1 ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  [[ -z $PACKAGE ]] || PACKAGE=$(readlink -f "$PACKAGE")
}

# ---------------------------------------------------------------------------
# Prompt helpers. Every prompt offers the variable's current value as default.
# ---------------------------------------------------------------------------

ask() { # VAR "Prompt" [validator]; validator "optional" allows an empty answer
  local __var=$1 __prompt=$2 __validator=${3-} __def __ans
  __def=${!__var:-}
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
v_cp_replicas() { [[ $1 =~ ^[135]$ ]] || { echo "      Use 1, 3 or 5 (3 for production)." >&2; return 1; }; }
v_file()  { [[ -r $1 ]] || { echo "      File not found or not readable: $1" >&2; return 1; }; }
v_endpoint() {
  [[ $1 =~ ^(https?://)?[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] && return 0
  echo "      Use host, host:port or https://host:port." >&2
  return 1
}

ip_responds() { ping -c1 -W1 "$1" >/dev/null 2>&1; }

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
                 [ping]=iputils-ping [ssh-keygen]=openssh-client [sha256sum]=coreutils [gpg]=gnupg )
  local -A rpm=( [curl]=curl [jq]=jq [openssl]=openssl [python3]=python3 [tar]=tar [gzip]=gzip
                 [ping]=iputils [ssh-keygen]=openssh-clients [sha256sum]=coreutils )
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
  ok "Base tools present (curl, jq, openssl, python3, ssh-keygen)"
}

docker_installed_version() {
  command -v docker >/dev/null || return 0
  docker --version 2>/dev/null | sed -nE 's/^Docker version ([0-9.]+).*/\1/p'
}

install_docker() {
  local cur pkgver
  cur=$(docker_installed_version)
  if [[ $cur == "$DOCKER_VERSION" ]]; then
    ok "Docker ${cur} already installed"
  else
    if [[ -n $cur ]]; then
      warn "Docker ${cur} is installed; the NKP 2.18 docs require ${DOCKER_VERSION}."
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
      pkgver=$(dnf -q list --showduplicates docker-ce 2>/dev/null | awk -v v="$DOCKER_VERSION" '$2 ~ (":" v "-") {print $2}' | tail -1)
      [[ -n $pkgver ]] || die "Docker ${DOCKER_VERSION} is not available in the Docker ${repo_os} repo."
      "${SUDO[@]}" dnf -y -q remove podman-docker docker docker-client docker-common docker-latest docker-engine >/dev/null 2>&1 || true
      if [[ -n $cur ]]; then
        "${SUDO[@]}" dnf versionlock delete docker-ce docker-ce-cli >/dev/null 2>&1 || true
        "${SUDO[@]}" dnf -y -q remove docker-ce docker-ce-cli
      fi
      "${SUDO[@]}" dnf -y -q install --allowerasing "docker-ce-${pkgver}" "docker-ce-cli-${pkgver}" containerd.io docker-buildx-plugin
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
  [[ -n $cur ]] && warn "kubectl ${cur} found; NKP 2.18 needs ${KUBECTL_MINOR}.x. Replacing /usr/local/bin/kubectl."
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
      < <(find "$dir" -maxdepth 1 -type f \( -name 'nkp_*linux_amd64.tar.gz' -o -name 'nkp-air-gapped-bundle_*linux_amd64.tar.gz' \) -print0 2>/dev/null)
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
      die "No NKP package found. Download nkp_<version>_linux_amd64.tar.gz from the Nutanix Portal and pass --package PATH."
    fi
  else
    [[ -r $PACKAGE ]] || die "Cannot read ${PACKAGE}"
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
  if [[ -f $ANSWERS_FILE ]] && ask_yn "Found answers from a previous run. Use them as defaults?" Y; then
    # shellcheck disable=SC1090
    . "$ANSWERS_FILE"
  fi
}

save_answers() {
  local k
  {
    echo "# NKP installer answers (no secrets). Generated $(date -Is)."
    for k in CLUSTER_NAME NUTANIX_ENDPOINT NUTANIX_USER TLS_MODE PC_CA_FILE NUTANIX_CLUSTER SUBNET NODE_CIDR \
             VM_IMAGE STORAGE_CONTAINER_NAME CONTROLPLANE_IP SERVICE_LB_IP_RANGE POD_CIDR SERVICE_CIDR SIZING \
             CP_REPLICAS CP_VCPUS CP_MEMORY WK_REPLICAS WK_VCPUS WK_MEMORY SSH_USERNAME SSH_PUBLIC_KEY \
             USE_DOCKERHUB DOCKERHUB_USERNAME USE_PROXY PROXY_HTTP PROXY_HTTPS PROXY_NO NTP_SERVERS ONBOARD_PC; do
      printf '%s=%q\n' "$k" "${!k:-}"
    done
  } >"$ANSWERS_FILE"
  chmod 600 "$ANSWERS_FILE"
}

q_cluster() {
  step "Cluster name"
  CLUSTER_NAME=${CLUSTER_NAME:-nkp-mgmt}
  ask CLUSTER_NAME "Management cluster name" v_cluster_name
  CLUSTER_DIR="${WORKDIR}/${CLUSTER_NAME}"
  mkdir -p "$CLUSTER_DIR" && chmod 700 "$CLUSTER_DIR"
}

setup_trust() {
  local rc=0 pem tb_help b64file
  PC_TLS_ARGS=()
  curl -s -o /dev/null --max-time 10 "${NUTANIX_ENDPOINT}/" || rc=$?
  case $rc in
    0) TLS_MODE=trusted; ok "Prism Central certificate is trusted by this host"; return ;;
    6|7|28) die "Cannot reach ${NUTANIX_ENDPOINT} (curl exit ${rc}). Check routing, firewall and DNS from the jump host." ;;
  esac
  warn "Prism Central's certificate is not trusted by this host (typical for the default self-signed certificate)."
  local modes=(fetched cafile insecure)
  local labels=("Fetch Prism Central's certificate and trust it (self-signed certificate)"
                "Use a CA certificate file I provide (certificate issued by an internal CA)"
                "Skip certificate verification (--insecure; labs only)")
  if [[ $TLS_MODE == trusted ]]; then TLS_MODE=""; fi
  TLS_MODE=${TLS_MODE:-fetched}
  pick TLS_MODE "How should NKP trust Prism Central" modes labels
  pem="${CLUSTER_DIR}/prism-central-ca.pem"
  case $TLS_MODE in
    insecure)
      PC_TLS_ARGS=(-k); TRUST_ARGS=(--insecure=true); return ;;
    fetched)
      local hostport=${NUTANIX_ENDPOINT#*://}
      openssl s_client -showcerts -connect "$hostport" </dev/null 2>/dev/null | openssl x509 -outform PEM >"$pem" \
        || die "Could not fetch the certificate from ${hostport}."
      openssl x509 -in "$pem" -noout -subject -issuer -enddate -fingerprint -sha256 | sed 's/^/      /' >&2
      ask_yn "Trust this certificate?" Y || die "Certificate not trusted. Rerun and choose another option."
      PC_TLS_ARGS=(-k) ;;
    cafile)
      ask PC_CA_FILE "Path to the CA certificate (PEM)" v_file
      openssl x509 -in "$PC_CA_FILE" -noout >/dev/null 2>&1 || die "${PC_CA_FILE} is not a PEM certificate."
      cp "$PC_CA_FILE" "$pem"
      PC_TLS_ARGS=(--cacert "$pem") ;;
  esac
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
  if ((PC_API_OK)); then
    mapfile -t pe_list < <(pc_api POST /api/nutanix/v3/clusters/list '{"kind":"cluster","length":500}' 2>/dev/null \
      | jq -r '.entities[] | select((.status.resources.config.service_list // []) | index("PRISM_CENTRAL") | not) | .status.name' | sort || true)
  fi
  pick NUTANIX_CLUSTER "Prism Element cluster for the nodes" pe_list

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
  pick SUBNET "Subnet for control plane and worker nodes (must have IPAM or DHCP)" subnet_vals subnet_labels

  NODE_POOLS=""
  if [[ -n $subnets_json ]]; then
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
  pick STORAGE_CONTAINER_NAME "Storage container for Kubernetes persistent volumes (on ${NUTANIX_CLUSTER})" sc_list
}

q_network() {
  step "Cluster IP addresses"
  info "Both values below must be static, unused, and outside the subnet's IPAM/DHCP pool."
  while :; do
    ask CONTROLPLANE_IP "Kubernetes API (control plane endpoint) IP" v_ip
    if [[ -n $NODE_POOLS ]] && ipcalc ip_in_ranges "$CONTROLPLANE_IP" "$NODE_POOLS"; then
      warn "${CONTROLPLANE_IP} is inside the IPAM pool ${NODE_POOLS}."; continue
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
  while :; do
    ask SERVICE_LB_IP_RANGE "Load balancer IP range for services (first-last; the NKP UI takes the first IP)" v_range
    if [[ -n $NODE_POOLS ]] && ipcalc range_overlaps "$SERVICE_LB_IP_RANGE" "$NODE_POOLS"; then
      warn "The range overlaps the IPAM pool ${NODE_POOLS}."; continue
    fi
    if ipcalc ip_in_ranges "$CONTROLPLANE_IP" "$SERVICE_LB_IP_RANGE"; then
      warn "The range contains the control plane IP ${CONTROLPLANE_IP}."; continue
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
  POD_CIDR=${POD_CIDR:-192.168.0.0/16}
  SERVICE_CIDR=${SERVICE_CIDR:-10.96.0.0/12}
  info "Pod and service networks are internal to the cluster and cannot be changed later."
  while :; do
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
                "Starter minimum: 3 control plane (2 vCPU, 8 GiB) + 2 workers (4 vCPU, 8 GiB)"
                "Custom")
  SIZING=${SIZING:-pro}
  pick SIZING "Choose a size" vals labels
  SIZING_ARGS=()
  case $SIZING in
    starter)
      SIZING_ARGS=(--control-plane-vcpus=2 --control-plane-memory=8 --worker-replicas=2 --worker-vcpus=4 --worker-memory=8)
      warn "Two workers cannot run the extra Pro/Ultimate platform apps if you upgrade the license later." ;;
    custom)
      CP_REPLICAS=${CP_REPLICAS:-3} CP_VCPUS=${CP_VCPUS:-4} CP_MEMORY=${CP_MEMORY:-16}
      WK_REPLICAS=${WK_REPLICAS:-4} WK_VCPUS=${WK_VCPUS:-8} WK_MEMORY=${WK_MEMORY:-32}
      ask CP_REPLICAS "Control plane nodes (1, 3 or 5)" v_cp_replicas
      ask CP_VCPUS "Control plane vCPUs per node" v_int
      ask CP_MEMORY "Control plane memory per node (GiB)" v_int
      ask WK_REPLICAS "Worker nodes" v_int
      ask WK_VCPUS "Worker vCPUs per node" v_int
      ask WK_MEMORY "Worker memory per node (GiB)" v_int
      ((CP_REPLICAS >= 3)) || warn "A single control plane node means losing the node loses the cluster."
      ((WK_REPLICAS >= 4)) || warn "Fewer than 4 workers: rook-ceph (logging, Velero, Insights) upgrades need 4."
      SIZING_ARGS=(--control-plane-replicas="$CP_REPLICAS" --control-plane-vcpus="$CP_VCPUS" --control-plane-memory="$CP_MEMORY"
                   --worker-replicas="$WK_REPLICAS" --worker-vcpus="$WK_VCPUS" --worker-memory="$WK_MEMORY") ;;
  esac
  if [[ $SIZING == starter && ${VM_IMAGE,,} != *rocky* ]]; then
    warn "The Starter license supports Rocky Linux images only; '${VM_IMAGE}' needs Pro or Ultimate."
  fi
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

  step "Container registry"
  info "Docker Hub limits anonymous image pulls; NKP recommends providing credentials."
  if ask_yn "Provide Docker Hub credentials?" "${USE_DOCKERHUB:-Y}"; then
    USE_DOCKERHUB=Y
    ask DOCKERHUB_USERNAME "Docker Hub username"
    ask_secret DOCKERHUB_PASSWORD "Docker Hub password or access token"
  else
    USE_DOCKERHUB=N
  fi
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
  ask NTP_SERVERS "NTP servers, comma-separated (blank = keep the image defaults)" optional
  if ask_yn "Register the cluster in Prism Central (NKP default)?" "${ONBOARD_PC:-Y}"; then ONBOARD_PC=Y; else ONBOARD_PC=N; fi
}

build_command() {
  CMD=(nkp create cluster nutanix
    --self-managed
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
    "${SIZING_ARGS[@]}")
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
  row "Prism Central" "$NUTANIX_ENDPOINT (user ${NUTANIX_USER}, TLS: ${TLS_MODE})"
  row "Prism Element" "$NUTANIX_CLUSTER"
  row "Subnet" "$SUBNET${NODE_CIDR:+ ($NODE_CIDR)}"
  row "Node image" "$VM_IMAGE"
  row "Storage container" "$STORAGE_CONTAINER_NAME"
  row "Control plane endpoint" "$CONTROLPLANE_IP"
  row "Load balancer range" "$SERVICE_LB_IP_RANGE (NKP UI: $(ipcalc range_first "$SERVICE_LB_IP_RANGE"))"
  row "Pod / service CIDR" "$POD_CIDR / $SERVICE_CIDR"
  row "Sizing" "$SIZING"
  row "SSH" "$SSH_USERNAME, key $SSH_PUBLIC_KEY"
  row "Docker Hub credentials" "$hub"
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
    ask_yn "Continue to cluster creation anyway?" N || { info "Answers saved; rerun with --skip-prereqs to fix them."; exit 1; }
  fi
}

run_create() {
  if ((PRINT_ONLY)); then
    info "--print-only: not creating the cluster. Command saved to ${CLUSTER_DIR}/create-cluster.cmd"
    exit 0
  fi
  ask_yn "Create the management cluster now?" Y || { info "Answers saved; rerun with --skip-prereqs when ready."; exit 0; }
  LOG="${CLUSTER_DIR}/create-cluster-$(date +%Y%m%d-%H%M%S).log"
  step "Creating ${CLUSTER_NAME} (log: ${LOG})"
  if ! (cd "$CLUSTER_DIR" && "${CMD[@]}") 2>&1 | tee -a "$LOG"; then
    err "Cluster creation failed. Full log: ${LOG}"
    info "If a local bootstrap cluster was left behind, remove it with: nkp delete bootstrap"
    info "Fix the cause, then rerun: ${SCRIPT_PATH} --skip-prereqs"
    exit 1
  fi
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
  if kubectl --kubeconfig "$kcfg" -n kommander wait --for condition=Ready helmreleases --all --timeout 30m; then
    ok "All platform applications are ready"
  else
    warn "Some applications are not ready yet. Check: kubectl --kubeconfig ${kcfg} -n kommander get helmreleases"
  fi
  step "NKP dashboard"
  nkp get dashboard --kubeconfig="$kcfg" || true
  cat >&2 <<EOF

    Next steps:
      export KUBECONFIG=${kcfg}
      nkp rotate dashboard-credentials        # then: nkp get dashboard
      Dashboard > Global > Settings > Licensing > Activate License   (key from the Nutanix Portal)
      Node pool commands on this cluster need: -n kommander
EOF
}

phase_setup() {
  step "Phase 2: interactive cluster setup"
  command -v nkp >/dev/null || die "nkp CLI not found. Run without --skip-prereqs first."
  ensure_docker_access
  if [[ -z ${TMUX:-} && -z ${STY:-} ]]; then
    warn "Not inside tmux or screen. Cluster creation takes 30-60 minutes and stops if this SSH session drops."
    ask_yn "Continue here anyway?" Y || exit 0
  fi
  PC_API_OK=0 TLS_MODE="" TRUST_ARGS=() NODE_CIDR="" NODE_POOLS=""
  load_answers
  q_cluster
  q_prism_central
  q_inventory
  q_network
  q_sizing
  q_access
  q_extras
  save_answers
  ok "Answers saved to ${ANSWERS_FILE} (no passwords)"
  build_command
  show_summary
  export NUTANIX_USER NUTANIX_PASSWORD
  run_preflight
  run_create
  post_install
}

main() {
  parse_args "$@"
  ((DO_PREREQS)) && phase_prereqs
  ((DO_SETUP)) && phase_setup
  return 0
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
