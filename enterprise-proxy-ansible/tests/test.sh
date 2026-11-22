#!/usr/bin/env bash
# Offline test of the four playbooks against the stand-in cluster in tests/bin/oc and tests/fixtures/state.json.
# Runs yamllint, ansible-lint and --syntax-check, then the playbooks in the runbook's order, and checks the
# cluster state, the recorded oc calls, the backups and that no credential reached a log or a leftover file.
# Needs ansible-core, ansible-lint and yamllint on PATH (the repo's .venv has them).
set -euo pipefail
cd "$(dirname "$0")/.."

export TEST_TMP; TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export OC_STATE="$TEST_TMP/state.json" OC_LOG="$TEST_TMP/oc.log"
export PATH="$PWD/tests/bin:$PATH"
export ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1
VARS="tests/fixtures/cluster.yml"
pass=0

ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
die()  { echo "  FAIL $1"; [ -f "$TEST_TMP/run.log" ] && tail -60 "$TEST_TMP/run.log"; exit 1; }
# run <playbook> [args]: expects success
run()  { ansible-playbook "$1" -e @"$VARS" "${@:2}" > "$TEST_TMP/run.log" 2>&1 < /dev/null || die "$1 ${*:2} failed"; cat "$TEST_TMP/run.log" >> "$TEST_TMP/all-runs.log"; }
# fails <pattern> <playbook> [args]: expects a failure whose output matches the pattern
fails() { local pat="$1"; shift; if ansible-playbook "$1" -e @"$VARS" "${@:2}" > "$TEST_TMP/run.log" 2>&1 < /dev/null; then die "$1 ${*:2} should have failed"; fi; grep -q "$pat" "$TEST_TMP/run.log" || die "$1 failed, but not with '$pat'"; cat "$TEST_TMP/run.log" >> "$TEST_TMP/all-runs.log"; }
# state <python expression over the state dict d>: must be true
state() { python3 -I -c "import json,sys,base64; d=json.load(open(sys.argv[1])); ps=json.loads(base64.b64decode(d['secret/pull-secret']['data']['.dockerconfigjson'])); sys.exit(0 if ($1) else 1)" "$OC_STATE" || die "state: $1"; }
logged() { grep -q -- "$1" "$OC_LOG" || die "oc was not called with: $1"; }
notlogged() { if grep -q -- "$1" "$OC_LOG"; then die "oc should not have been called with: $1"; fi; }

echo "== lint"
yamllint . || die yamllint
ansible-lint --offline . > "$TEST_TMP/lint.log" 2>&1 < /dev/null || { cat "$TEST_TMP/lint.log"; die ansible-lint; }
for p in retrofit update remove-mirror verify; do
  ansible-playbook --syntax-check "$p-playbook.yml" -e @"$VARS" > "$TEST_TMP/run.log" 2>&1 < /dev/null || die "syntax $p"
done
ok "yamllint, ansible-lint, syntax-check"

echo "== an unhealthy cluster is refused before anything changes"
python3 -I - "$OC_STATE" <<'PY'
import json, sys
d = json.load(open('tests/fixtures/state.json'))
d['clusteroperators'][0]['status']['conditions'][2]['status'] = 'True'   # authentication Degraded
json.dump(d, open(sys.argv[1], 'w'))
PY
: > "$OC_LOG"
fails "Not healthy" retrofit-playbook.yml --tags pull-secret,image-policy
grep -q "authentication" "$TEST_TMP/run.log" || die "the degraded operator is not named"
notlogged "patch"; notlogged "set data"
ok "degraded ClusterOperator stops phase 1; no patch, no set data"

echo "== phases 1 to 3: backup, check, pull secret, image policy"
cp tests/fixtures/state.json "$OC_STATE"; : > "$OC_LOG"
run retrofit-playbook.yml --tags pull-secret,image-policy
B="$TEST_TMP/backups/testcluster-$(date +%F)"
[ -s "$B/pull-secret.yaml" ] && [ -s "$B/proxy.yaml" ] && [ -s "$B/subscriptions.yaml" ] || die "backups missing in $B"
[ "$(stat -c %a "$B/pull-secret.yaml")" = "600" ] || die "pull-secret.yaml is not 0600"
[ "$(stat -c %a "$B")" = "700" ] || die "backup folder is not 0700"
[ ! -e "$B/work/merged-pull-secret.json" ] || die "merged-pull-secret.json left behind"
state "set(ps['auths']) == {'quay.io','registry.redhat.io','registry-dc1.example.com:8443'}"
state "ps['auths']['registry-dc1.example.com:8443']['auth'] == 'bWlycm9yOm1pcnJvcg=='"
state "'blockedRegistries' not in d['image.config.openshift.io/cluster']['spec']['registrySources']"
state "d['image.config.openshift.io/cluster']['spec']['registrySources']['allowedRegistries'] == ['quay.io/openshift-release-dev','registry.redhat.io','registry.access.redhat.com','image-registry.openshift-image-registry.svc:5000','registry-dc1.example.com:8443']"
state "'httpsProxy' not in d['proxy/cluster']['spec']"
logged "set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="
logged '"op":"remove","path":"/spec/registrySources/blockedRegistries"'
logged "debug node/master-0"
notlogged "patch proxy/cluster"
ok "pull secret merged (mirror login kept, telemetry entry dropped), blockedRegistries replaced by allowedRegistries, proxy untouched"

echo "== phase 4: the proxy (tag proxy, never runs by default)"
: > "$OC_LOG"
run retrofit-playbook.yml --tags proxy
state "d['proxy/cluster']['spec']['httpsProxy'] == 'http://proxy.example.com:3128'"
state "d['proxy/cluster']['spec']['httpProxy'] == 'http://proxy.example.com:3128'"
state "d['proxy/cluster']['spec']['noProxy'] == '.apps.testcluster.example.com,api-int.testcluster.example.com,.example.com,10.10.0.0/16'"
state "d['proxy/cluster']['spec']['readinessEndpoints'] == ['https://mirror.openshift.com','https://quay.io']"
state "d['proxy/cluster']['spec']['trustedCA'] == {'name': 'user-ca-bundle'}"
state "'MIIBtest-not-a-real-certificate' in d['configmaps/openshift-config']['user-ca-bundle']['data']['ca-bundle.crt']"
logged "create configmap user-ca-bundle -n openshift-config --from-file=ca-bundle.crt="
logged "patch proxy/cluster --type merge --patch-file"
logged "cat /etc/mco/proxy.env"
ok "proxy/cluster patched with the CA ConfigMap, readiness endpoints and noProxy; pools and operators waited for"

echo "== phase 4 again: the CA is already in the bundle, so the ConfigMap is not touched"
: > "$OC_LOG"
run retrofit-playbook.yml --tags proxy
notlogged "set data configmap/user-ca-bundle"; notlogged "create configmap"
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); b=d['configmaps/openshift-config']['user-ca-bundle']['data']['ca-bundle.crt']; sys.exit(0 if b.count('BEGIN CERTIFICATE')==1 else 1)" "$OC_STATE" || die "the proxy CA was added twice"
ok "proxy CA added once"

echo "== phases 6 and 7: update checks and catalogs from Red Hat"
: > "$OC_LOG"
run retrofit-playbook.yml --tags update-service,catalogs
state "'upstream' not in d['clusterversion/version']['spec']"
state "d['operatorhub/cluster']['spec'] == {'disableAllDefaultSources': True, 'sources': [{'name': 'redhat-operators', 'disabled': False}]}"
state "all(s['spec']['source']=='redhat-operators' and s['spec']['sourceNamespace']=='openshift-marketplace' for s in d['subscriptions'])"
state "all(s['spec']['installPlanApproval']=='Manual' for s in d['subscriptions'])"
state "[s['spec']['channel'] for s in d['subscriptions']] == ['stable-6.2','v1']"
state "all(s['status']['state']=='AtLatestKnown' for s in d['subscriptions'])"
logged '"op":"remove","path":"/spec/upstream"'
logged "packagemanifests -l catalog=redhat-operators"
ok "spec.upstream removed, only redhat-operators enabled, both Subscriptions moved with Manual approval and their channels kept"

echo "== phase 7 with an operator the stock catalog lacks"
python3 -I - "$OC_STATE" <<'PY'
import json, sys
d = json.load(open('tests/fixtures/state.json'))
d['packagemanifests']['redhat-operators'].remove('cincinnati-operator')
json.dump(d, open(sys.argv[1], 'w'))
PY
fails "ResolutionFailed" retrofit-playbook.yml --tags catalogs
grep -q "openshift-update-service/cincinnati-operator" "$TEST_TMP/run.log" || die "the failing Subscription is not named"
ok "ResolutionFailed is reported with the Subscription's name"

echo "== phase 8: the first connected update"
cp tests/fixtures/state.json "$OC_STATE"; : > "$OC_LOG"
run retrofit-playbook.yml --tags pull-secret,image-policy,update-service,catalogs
run retrofit-playbook.yml --tags proxy
: > "$OC_LOG"
run update-playbook.yml
state "d['clusterversion/version']['spec']['channel'] == 'eus-4.20'"
state "d['clusterversion/version']['status']['history'][0] == {'version': '4.20.39', 'state': 'Completed', 'verified': True}"
logged "adm upgrade channel eus-4.20"
logged "adm upgrade --to=4.20.39"
logged "registries.conf"
ok "channel changed, update to 4.20.39 requested, completion and signature verification checked"

echo "== phase 8 refuses to run before phase 6"
python3 -I - "$OC_STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['clusterversion/version']['spec']['upstream'] = 'https://osus.apps.testcluster.example.com/api/upgrades_info/v1/graph'
json.dump(d, open(sys.argv[1], 'w'))
PY
: > "$OC_LOG"
fails "spec.upstream" update-playbook.yml
notlogged "adm upgrade --to"
ok "a local Update Service in spec.upstream stops the update"
python3 -I - "$OC_STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); del d['clusterversion/version']['spec']['upstream']; json.dump(d, open(sys.argv[1], 'w'))
PY

echo "== phase 9: remove the mirror"
: > "$OC_LOG"
run remove-mirror-playbook.yml
state "all(v == [] for v in d['mirror-sets'].values())"
state "[c['metadata']['name'] for c in d['catalogsources']] == ['redhat-operators']"
state "d['updateservices'] == []"
state "d['image.config.openshift.io/cluster']['spec']['registrySources']['allowedRegistries'] == ['quay.io/openshift-release-dev','registry.redhat.io','registry.access.redhat.com','image-registry.openshift-image-registry.svc:5000']"
state "d['configmaps/openshift-config']['registry-config']['data'] == {}"
state "set(ps['auths']) == {'quay.io','registry.redhat.io'}"
logged "delete imagedigestmirrorset idms-release-0"
logged "delete imagedigestmirrorset idms-operator-0"
logged "delete imagetagmirrorset itms-release-0"
notlogged "delete imagecontentsourcepolicy"
logged "delete catalogsource cs-redhat-operator-index-v4-18 -n openshift-marketplace"
logged "delete updateservice --all -n openshift-update-service"
[ ! -e "$B/work/trimmed-pull-secret.json" ] || die "trimmed-pull-secret.json left behind"
[ -s "$B/phase9-mirror-sets.yaml" ] || die "phase 9 backup missing"
ok "mirror sets, mirrored catalog, OSUS, mirror registry entry, mirror CA key and mirror login removed; node registries.conf checked"

echo "== phase 9 refuses to run while a Subscription still uses the mirrored catalog"
python3 -I - "$OC_STATE" <<'PY'
import json, sys
d = json.load(open('tests/fixtures/state.json')); d['clusterversion/version']['spec'].pop('upstream')
json.dump(d, open(sys.argv[1], 'w'))
PY
: > "$OC_LOG"
fails "Subscriptions still on a mirrored source" remove-mirror-playbook.yml
notlogged "delete"
ok "nothing deleted"

echo "== verify: the runbook's tests 1 to 10"
cp tests/fixtures/state.json "$OC_STATE"
run retrofit-playbook.yml --tags pull-secret,image-policy,update-service,catalogs
run retrofit-playbook.yml --tags proxy
: > "$OC_LOG"
run verify-playbook.yml
E=$(ls "$TEST_TMP"/backups/testcluster-verify-*.txt)
for n in 1 2 3 4 5 6 8 9 10; do grep -q "^$n  PASS" "$E" || { cat "$E"; die "test $n not PASS in the evidence file"; }; done
grep -q "Source image rejected" "$E" || die "test 9 detail missing"
logged "create namespace proxy-verify"; logged "delete pod t t2 -n proxy-verify"; logged "delete namespace proxy-verify"
state "d['testpods'] == {}"
[ "$(stat -c %a "$E")" = "600" ] || die "evidence file is not 0600"
ok "evidence file written, all nine automated tests PASS, test pods and namespace cleaned up"

echo "== verify fails when a workload pod gets proxy variables"
cat > "$TEST_TMP/env-proxy.sh" <<'SH'
#!/usr/bin/env bash
# a stand-in whose `oc exec ... env` shows a proxy variable
if [ "$1" = exec ] && [ "${@: -1}" = env ]; then echo "HTTPS_PROXY=http://proxy.example.com:3128"; exit 0; fi
exec "$(dirname "$0")/../oc-real" "$@"
SH
mkdir -p "$TEST_TMP/bin"; cp tests/bin/oc "$TEST_TMP/oc-real"; cp "$TEST_TMP/env-proxy.sh" "$TEST_TMP/bin/oc"; chmod +x "$TEST_TMP/bin/oc" "$TEST_TMP/oc-real"
PATH="$TEST_TMP/bin:$PATH" fails "A workload pod gets no proxy" verify-playbook.yml
E=$(ls -t "$TEST_TMP"/backups/testcluster-verify-*.txt | head -1)
grep -q "^6  FAIL" "$E" || die "test 6 should be FAIL"
grep -q "Failed: \['A workload pod gets no proxy'\]" "$TEST_TMP/run.log" || die "the failure message should name test 6 only"
ok "test 6 fails and the playbook fails with it"

echo "== no credential in any Ansible output"
for tok in dGVzdDpxdWF5 dGVzdDpyaA bWlycm9yOm1pcnJvcg dGVzdDpjbG91ZA; do
  if grep -q "$tok" "$TEST_TMP/all-runs.log"; then die "token $tok appeared in the Ansible output"; fi
done
ok "pull-secret tokens never printed"

echo
echo "all $pass checks passed"
