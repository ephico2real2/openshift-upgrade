#!/usr/bin/env bash
# Exercise the OLM admission policies against a kind cluster; prints ALLOWED/DENIED per case
# and exits non-zero if any case does not match its expected outcome.
set -u
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
fail=0

run() {
  local expect="$1" name="$2" manifest="$3" out result
  if out=$(printf '%s\n' "$manifest" | kubectl apply --dry-run=server -f - 2>&1); then
    result=ALLOWED
  else
    result=DENIED
  fi
  printf '%-8s expect=%-7s %-58s | %s\n' "$result" "$expect" "$name" "$(echo "$out" | tail -1 | cut -c1-170)"
  [[ "$result" == "$expect" ]] || fail=1
}

cs() { # ns name extra-spec [annotations-block]
  cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $2
  namespace: $1
${4:-}
spec:
$3
EOF
}

run ALLOWED "CS approved image in openshift-marketplace" \
  "$(cs openshift-marketplace approved-operators '  sourceType: grpc
  image: mirror.corp.example.com/olm/approved-catalog:v4.18')"
run DENIED  "CS approved image in developer namespace" \
  "$(cs dev-team rogue '  sourceType: grpc
  image: mirror.corp.example.com/olm/approved-catalog:v4.18')"
run DENIED  "CS unapproved image (quay.io) in openshift-marketplace" \
  "$(cs openshift-marketplace rogue '  sourceType: grpc
  image: quay.io/evil/catalog:latest')"
run DENIED  "CS prefix-spoof host mirror.corp.example.com.evil.io" \
  "$(cs openshift-marketplace rogue '  sourceType: grpc
  image: mirror.corp.example.com.evil.io/olm/catalog:v1')"
run DENIED  "CS configmap sourceType" \
  "$(cs openshift-marketplace rogue '  sourceType: configmap
  configMap: rogue-cm')"
run DENIED  "CS grpc address (no image)" \
  "$(cs openshift-marketplace rogue '  sourceType: grpc
  address: rogue.example.com:50051')"
run DENIED  "CS approved image + unapproved catalogImageTemplate" \
  "$(cs openshift-marketplace rogue '  sourceType: grpc
  image: mirror.corp.example.com/olm/approved-catalog:v4.18' '  annotations:
    olm.catalogImageTemplate: "quay.io/evil/catalog:v{kube_major_version}.{kube_minor_version}"')"

run ALLOWED "CS approved image + approved catalogImageTemplate" \
  "$(cs openshift-marketplace approved-templated '  sourceType: grpc
  image: mirror.corp.example.com/olm/approved-catalog:v4.18' '  annotations:
    olm.catalogImageTemplate: "mirror.corp.example.com/olm/approved-catalog:v{kube_major_version}.{kube_minor_version}"')"

exit $fail
