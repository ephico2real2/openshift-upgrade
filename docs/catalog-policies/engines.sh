#!/usr/bin/env bash
# Test the Kyverno and Gatekeeper CatalogSource policies on a K8s 1.35 kind cluster (OCP 4.22 base).
set -u
cd "$(dirname "$0")"
export KIND_EXPERIMENTAL_PROVIDER=podman
name=olm-engines
export KUBECONFIG="$PWD/$name.kubeconfig"
kind create cluster --name "$name" --image kindest/node:v1.35.8 --kubeconfig "$KUBECONFIG" --wait 180s >/dev/null 2>&1 || { echo "create failed"; exit 1; }
kubectl version 2>/dev/null | grep Server
kubectl apply --server-side -f olm-crds.yaml >/dev/null
kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null
kubectl create ns openshift-marketplace >/dev/null; kubectl create ns dev-team >/dev/null

echo "===== Kyverno v1.19.1"
kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.19.1/install.yaml >/dev/null 2>&1 || echo "kyverno install returned non-zero"
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=300s
kubectl apply -f kyverno-olm-catalogs.yaml
kubectl wait --for=condition=Ready clusterpolicy/restrict-olm-catalogsources --timeout=120s
sleep 5
bash test-cs.sh; echo "kyverno suite exit=$?"
kubectl delete -f kyverno-olm-catalogs.yaml >/dev/null
kubectl delete -f https://github.com/kyverno/kyverno/releases/download/v1.19.1/install.yaml >/dev/null 2>&1
kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l webhook.kyverno.io/managed-by=kyverno >/dev/null 2>&1
sleep 10

echo "===== Gatekeeper v3.23.1"
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.23.1/deploy/gatekeeper.yaml >/dev/null
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager --timeout=300s
kubectl apply -f gatekeeper-olm-catalogs.yaml 2>&1 | head -3
for i in $(seq 1 30); do kubectl get olmcatalogsourcerestrict restrict-olm-catalogsources >/dev/null 2>&1 && break; sleep 3; kubectl apply -f gatekeeper-olm-catalogs.yaml >/dev/null 2>&1; done
kubectl get constrainttemplate olmcatalogsourcerestrict -o jsonpath='{.status.created}{"\n"}'
sleep 15
bash test-cs.sh; echo "gatekeeper suite exit=$?"
kind delete cluster --name "$name" >/dev/null 2>&1
