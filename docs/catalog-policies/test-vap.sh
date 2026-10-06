#!/usr/bin/env bash
# Exercise the OLM admission policies against a kind cluster; prints ALLOWED/DENIED per case
# and exits non-zero if any case does not match its expected outcome.
set -u
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
fail=0

run() {
  local expect="$1" name="$2" manifest="$3" as="${4:-}" out result
  if out=$(printf '%s\n' "$manifest" | kubectl apply --dry-run=server ${as:+--as="$as"} -f - 2>&1); then
    result=ALLOWED
  elif grep -q "ValidatingAdmissionPolicy .* denied request" <<<"$out"; then
    result=DENIED   # denied by an admission policy, not by RBAC or schema validation
  else
    result=ERROR
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

sub() { # ns source sourceNamespace approval-line
  cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: example
  namespace: $1
spec:
  channel: stable
  name: example-operator
  source: $2
  sourceNamespace: $3
$4
EOF
}
run ALLOWED "SUB approved catalog, Manual" "$(sub dev-team approved-operators openshift-marketplace '  installPlanApproval: Manual')"
run DENIED  "SUB non-approved catalog (community-operators)" "$(sub dev-team community-operators openshift-marketplace '  installPlanApproval: Manual')"
run DENIED  "SUB namespace-local catalog" "$(sub dev-team approved-operators dev-team '  installPlanApproval: Manual')"
run DENIED  "SUB Automatic approval" "$(sub dev-team approved-operators openshift-marketplace '  installPlanApproval: Automatic')"
run DENIED  "SUB approval unset (defaults to Automatic)" "$(sub dev-team approved-operators openshift-marketplace '')"
OLM_SA=system:serviceaccount:openshift-operator-lifecycle-manager:olm-operator-serviceaccount
run ALLOWED "SUB Automatic created by OLM SA (dependency path)" "$(sub dev-team approved-operators openshift-marketplace '  installPlanApproval: Automatic')" "$OLM_SA"
run DENIED  "SUB by OLM SA from non-approved catalog" "$(sub dev-team community-operators openshift-marketplace '  installPlanApproval: Automatic')" "$OLM_SA"
run DENIED  "SUB Automatic created by another SA" "$(sub dev-team approved-operators openshift-marketplace '  installPlanApproval: Automatic')" "system:serviceaccount:dev-team:default"

cc() { # name ref
  cat <<EOF
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  name: $1
spec:
  source:
    type: Image
    image:
      ref: $2
EOF
}
run ALLOWED "CC approved ref" "$(cc approved-catalog mirror.corp.example.com/olm/approved-catalog:v4.18)"
run DENIED  "CC unapproved ref (quay.io)" "$(cc rogue-catalog quay.io/evil/catalog:latest)"
run ALLOWED "CC default name, registry.redhat.io ref" "$(cc openshift-redhat-operators registry.redhat.io/redhat/redhat-operator-index:v4.18)"
run DENIED  "CC default name repointed to quay.io" "$(cc openshift-redhat-operators quay.io/evil/catalog:latest)"

exit $fail
