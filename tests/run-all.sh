#!/usr/bin/env bash
# Runs every offline test: syntax and lint checks, the nkp_lab.py unit tests and the three shell suites.
# Needs bash 4+, python3 3.9+ and openssl; shellcheck is used when installed. Nothing touches a real lab.
#   tests/run-all.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
if ((BASH_VERSINFO[0] < 4)); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash /tmp/bash5/bin/bash; do
    if [[ -x $b ]]; then exec "$b" "$0" "$@"; fi
  done
  echo "bash 4 or newer is needed (macOS: brew install bash)" >&2
  exit 1
fi
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/nkp-tests.XXXX")
PATH="$(dirname "$BASH"):$PATH"
export TMPDIR PATH
trap 'rm -rf "$TMPDIR"' EXIT

failed=()
run() { # name command...
  local name=$1 log="$TMPDIR/$1.log"; shift
  if "$@" >"$log" 2>&1; then
    printf '  PASS  %-12s %s\n' "$name" "$(grep -v '^$' "$log" | tail -1)"
  else
    printf '  FAIL  %s\n' "$name"; tail -40 "$log" | sed 's/^/        /'
    failed+=("$name")
  fi
}

run syntax bash -n "$ROOT/nkp-jumphost-setup.sh"
if command -v shellcheck >/dev/null; then run shellcheck shellcheck -x "$ROOT/nkp-jumphost-setup.sh"
else echo "  SKIP  shellcheck   not installed"; fi
run py-syntax python3 -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' \
  "$ROOT/nkp_lab.py" "$ROOT/test_nkp_lab.py"
run unit bash -c "cd '$ROOT' && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_nkp_lab"
run mock "$BASH" "$HERE/mock.sh"
run integration "$BASH" "$HERE/integration.sh"
run lab-e2e "$BASH" "$HERE/lab-e2e.sh"

if ((${#failed[@]})); then echo "Failed: ${failed[*]}"; exit 1; fi
echo "All passed."
