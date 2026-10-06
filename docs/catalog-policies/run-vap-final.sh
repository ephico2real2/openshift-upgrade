#!/usr/bin/env bash
# Final VAP run on the locally cached default kind node image (no new image pull).
set -u
cd "$(dirname "$0")"
export KIND_EXPERIMENTAL_PROVIDER=podman
name=olm-vap-final
export KUBECONFIG="$PWD/$name.kubeconfig"
kind create cluster --name "$name" ${KIND_IMAGE:+--image "$KIND_IMAGE"} --kubeconfig "$KUBECONFIG" --wait 120s >/dev/null 2>&1 || echo "note: create returned non-zero (node readiness not required for admission tests)"
kubectl version 2>/dev/null | grep Server
kubectl apply --server-side -f olm-crds.yaml >/dev/null
kubectl apply --server-side -f clustercatalog-crd.yaml >/dev/null
kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null
kubectl create ns openshift-marketplace >/dev/null; kubectl create ns dev-team >/dev/null
# Give the impersonated service accounts RBAC so any denial observed is from admission, not RBAC.
kubectl create clusterrolebinding test-olm-sa --clusterrole=cluster-admin --serviceaccount=openshift-operator-lifecycle-manager:olm-operator-serviceaccount >/dev/null
kubectl create clusterrolebinding test-dev-sa --clusterrole=cluster-admin --serviceaccount=dev-team:default >/dev/null
kubectl apply -f vap-olm-catalogs.yaml
sleep 5
kubectl get validatingadmissionpolicy -o custom-columns=NAME:.metadata.name,TYPECHECK:.status.typeChecking
bash test-vap.sh; echo "suite exit=$?"
kind delete cluster --name "$name" >/dev/null 2>&1
