#!/usr/bin/env bash
# Scenario B (no registry of your own): stock redhat-operators catalog + package/channel allowlist.
set -u
export KUBECONFIG="${KUBECONFIG:?}"
fail=0
run() {
  local expect="$1" name="$2" manifest="$3" as="${4:-}" out result
  if out=$(printf '%s\n' "$manifest" | kubectl apply --dry-run=server ${as:+--as="$as"} -f - 2>&1); then result=ALLOWED
  elif grep -q "ValidatingAdmissionPolicy .* denied request" <<<"$out"; then result=DENIED
  else result=ERROR; fi
  printf '%-8s expect=%-7s %-52s | %s\n' "$result" "$expect" "$name" "$(echo "$out" | tail -1 | sed 's/.*denied request: //' | cut -c1-90)"
  [[ "$result" == "$expect" ]] || fail=1
}
sub() { cat <<EOT
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: t, namespace: dev-team}
spec:
  name: $1
  source: $2
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
$3
EOT
}
cs() { cat <<EOT
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata: {name: $1, namespace: openshift-marketplace}
spec: {sourceType: grpc, image: "$2"}
EOT
}
run ALLOWED "SUB approved package + approved channel"   "$(sub openshift-gitops-operator redhat-operators '  channel: gitops-1.18')"
run DENIED  "SUB approved package, unapproved channel"  "$(sub openshift-gitops-operator redhat-operators '  channel: latest')"
run DENIED  "SUB approved package, channel omitted"     "$(sub openshift-gitops-operator redhat-operators '')"
run DENIED  "SUB unapproved package"                    "$(sub rhods-operator redhat-operators '  channel: stable')"
run DENIED  "SUB approved package from certified catalog" "$(sub openshift-gitops-operator certified-operators '  channel: gitops-1.18')"
run ALLOWED "CS stock redhat-operator-index"            "$(cs redhat-operators registry.redhat.io/redhat/redhat-operator-index:v4.18)"
run DENIED  "CS community-operator-index"               "$(cs community-operators registry.redhat.io/redhat/community-operator-index:v4.18)"
run DENIED  "CS arbitrary quay.io index"                "$(cs rogue quay.io/evil/catalog:latest)"
exit $fail
