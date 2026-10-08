#!/usr/bin/env bash
# Offline test of kyverno-workload-image-repos.yaml with the kyverno CLI (tested with v1.19.1).
# The expected result is in each fixture's file name: allow-* pass, deny-* fail, skip-* skip.
# Each case is checked on its own: `kyverno test` reported an invalid policy as passing.
set -u
cd "$(dirname "$0")"
K=${KYVERNO:-kyverno}
bad=0
for f in tests/*.yaml; do
  n=$(basename "$f" .yaml)
  case "$n" in allow-*) want="pass: 1, fail: 0";; deny-*) want="pass: 0, fail: 1";; skip-*) want="pass: 0, fail: 0, warn: 0, error: 0, skip: 1";; esac
  got=$("$K" apply kyverno-workload-image-repos.yaml -r "$f" 2>/dev/null | grep '^pass:')
  if [[ "$got" == *"$want"* && "$got" == *"error: 0"* ]]; then echo "ok   $n"; else echo "FAIL $n: $got"; bad=1; fi
done
exit $bad
