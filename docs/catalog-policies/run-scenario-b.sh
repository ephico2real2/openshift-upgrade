#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
export KIND_EXPERIMENTAL_PROVIDER=podman
name=olm-vap-b
export KUBECONFIG="$PWD/$name.kubeconfig"
kind create cluster --name "$name" ${KIND_IMAGE:+--image "$KIND_IMAGE"} --kubeconfig "$KUBECONFIG" --wait 120s >/dev/null 2>&1 || echo "note: create returned non-zero"
kubectl version 2>/dev/null | grep Server
kubectl apply --server-side -f olm-crds.yaml >/dev/null
kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null
kubectl create ns openshift-marketplace >/dev/null; kubectl create ns dev-team >/dev/null
kubectl apply -f vap-olm-package-allowlist.yaml >/dev/null
sleep 5
kubectl get validatingadmissionpolicy -o custom-columns=NAME:.metadata.name,TYPECHECK:.status.typeChecking
bash test-scenario-b.sh; echo "suite exit=$?"
kind delete cluster --name "$name" >/dev/null 2>&1
