#!/usr/bin/env bash
# Re-run the VAP test suite on the Kubernetes minors that back OCP 4.18 (1.31) and OCP 4.22 (1.35).
set -u
cd "$(dirname "$0")"
export KIND_EXPERIMENTAL_PROVIDER=podman
for img in kindest/node:v1.31.14 kindest/node:v1.35.8; do
  name="olm-vap-$(echo "$img" | sed 's/.*:v//; s/\./-/g')"
  kc="$PWD/$name.kubeconfig"
  echo "===== $img ($name)"
  kind create cluster --name "$name" --image "$img" --kubeconfig "$kc" --wait 180s >/dev/null 2>&1 || { echo "cluster create failed"; continue; }
  export KUBECONFIG="$kc"
  kubectl version 2>/dev/null | grep Server
  kubectl apply --server-side -f olm-crds.yaml >/dev/null
  kubectl apply --server-side -f clustercatalog-crd.yaml >/dev/null
  kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null
  kubectl apply -f vap-olm-catalogs.yaml >/dev/null
  kubectl create ns openshift-marketplace >/dev/null
  kubectl create ns dev-team >/dev/null
  sleep 5  # let the policy informer observe the new policies/bindings
  bash test-vap.sh; echo "suite exit=$?"
  kind delete cluster --name "$name" >/dev/null 2>&1
done
