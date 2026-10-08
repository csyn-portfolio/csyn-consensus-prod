#!/usr/bin/env bash
# Decide what the visibility probe's exit code is allowed to write.
#
# Exit 1 is Node's code for an uncaught exception as well as the script's
# NOT SEEN verdict. Writing 0 for every exit 1 turns a crash into a false
# "network cannot see us" warning while the heartbeat stays healthy.
#
# A verdict is written only when the probe's own line is in the output:
#   exit 0 and a line containing "SEEN on "  -> write-1, job success
#   exit 1 and a line containing "NOT SEEN:" -> write-0, job failure
#   exit 2                                   -> none,    job success
#   anything else                            -> none,    job failure
#
# stdout is one of: write-1, write-0, none

set -euo pipefail

CODE="${1:?exit code required}"
PROBE="${2:?probe output path required}"

if [ ! -f "$PROBE" ]; then
  echo none
  exit 1
fi

case "$CODE" in
  0)
    if grep -F -q "SEEN on " "$PROBE"; then
      echo write-1
      exit 0
    fi
    echo none
    exit 1
    ;;
  1)
    if grep -F -q "NOT SEEN:" "$PROBE"; then
      echo write-0
      exit 1
    fi
    echo none
    exit 1
    ;;
  2)
    echo none
    exit 0
    ;;
  *)
    echo none
    exit 1
    ;;
esac
