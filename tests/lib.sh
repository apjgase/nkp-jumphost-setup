# shellcheck shell=bash
# Sourced by the shell test suites: paths, a scratch directory and portable helpers (GNU and BSD tools).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NKPDIR=$(dirname "$HERE")
S="$NKPDIR/nkp-jumphost-setup.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nkp-tests.XXXX")

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sedi() { local f=${*: -1}; sed -i.bak "$@" && rm -f "$f.bak"; }

fake_lab() { # sets T2: a copy of tests/fake with a fresh certificate for 127.0.0.1, and puts its stubs first on PATH
  T2=$SCRATCH/fake
  mkdir -p "$T2" && cp -R "$HERE/fake/." "$T2/"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=127.0.0.1 \
    -addext subjectAltName=IP:127.0.0.1 -addext basicConstraints=critical,CA:TRUE \
    -keyout "$T2/key.pem" -out "$T2/cert.pem" 2>/dev/null \
    || { echo "openssl could not create the test certificate (needs -addext: OpenSSL 1.1.1+ or LibreSSL 3+)" >&2; exit 1; }
  export PATH="$T2/bin:$PATH" NKP_DIR=$NKPDIR
}
