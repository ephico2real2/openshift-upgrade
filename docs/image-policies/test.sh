#!/usr/bin/env bash
# Offline test with the kyverno CLI (tested with v1.19.1): kyverno test .kyverno-test
# The ConfigMap in allowed-image-registries.yaml is copied into the test context first, so the
# test runs against the list we actually apply. The run fails if any case is reported with a
# reason other than Ok or Excluded: `kyverno test` counts an invalid policy as passing otherwise.
set -u
cd "$(dirname "$0")"
K=${KYVERNO:-kyverno}
{ printf 'apiVersion: cli.kyverno.io/v1alpha1\nkind: Context\nmetadata:\n  name: context\nspec:\n  resources:\n'
  grep -v '^#' allowed-image-registries.yaml | sed 's/^/    /; 1s/^    /  - /'; } > .kyverno-test/context.yaml
out=$("$K" test .kyverno-test 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
echo "$out" | grep -E '^│ [0-9]|Test Summary'
rows=$(echo "$out" | grep -cE '^│ [0-9]')
bad=$(echo "$out" | grep -E '^│ [0-9]' | grep -vcE '│ Pass +│ (Ok|Excluded) +│')
echo "$out" | grep -q '0 tests failed' && [ "$rows" -gt 0 ] && [ "$bad" -eq 0 ] || { echo "FAILED ($bad bad rows of $rows)"; exit 1; }
