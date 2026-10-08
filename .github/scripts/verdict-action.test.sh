#!/usr/bin/env bash
# The crash case is the plant: exit 1 with a stack and no NOT SEEN line must
# not come back as write-0. That is what a top-level throw in
# tools/network-sees-validator.mjs looks like to this workflow.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/verdict-action.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check() {
  local name="$1" code="$2" body="$3" want_action="$4" want_rc="$5"
  printf '%s\n' "$body" > "$TMP/out"
  set +e
  got="$(bash "$SCRIPT" "$code" "$TMP/out")"
  rc=$?
  set -e
  if [ "$got" != "$want_action" ] || [ "$rc" != "$want_rc" ]; then
    echo "FAIL $name got=$got rc=$rc want=$want_action rc=$want_rc"
    fail=1
  else
    echo "ok $name"
  fi
}

check crash 1 $'Error: boom\n    at Object.<anonymous> (tools/network-sees-validator.mjs:1:1)' none 1
check notseen 1 $'NOT SEEN: 2 feeds carried untrusted validations and none showed us.' write-0 1
check seen 0 $'SEEN on 3/3 independent public feeds — multi-path propagation confirmed.' write-1 0
check inconclusive 2 $'INCONCLUSIVE: fewer than 2 feeds were in a state that could have shown us.' none 0
check exit0-without-seen 0 'probe started' none 1
# Progress lines are not verdicts. "seen on " is lowercase on purpose.
check per-feed-seen 0 $'  validations=18 validators=40 ours=18 :: seen on 18 ledgers, unbroken run 18' none 1
check per-feed-not-ours 1 $'  validations=18 validators=40 ours=0 :: carried untrusted validations but NOT ours' none 1

set +e
got="$(bash "$SCRIPT" 1 "$TMP/no-such-file")"
rc=$?
set -e
if [ "$got" != "none" ] || [ "$rc" != "1" ]; then
  echo "FAIL missing-path got=$got rc=$rc"
  fail=1
else
  echo "ok missing-path"
fi

if [ "$fail" != 0 ]; then
  exit 1
fi
echo "verdict-action: pass"
