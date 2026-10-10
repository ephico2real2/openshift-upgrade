# How we do Step 2: retrofit, update, remove the mirror, verify

These playbooks convert a disconnected cluster so it reaches Red Hat through the enterprise proxy, and run its
updates afterwards. This is the north star: the conversion is automated, as the mirroring is today. The runbook
[`docs/enterprise-proxy/README.md`](../docs/enterprise-proxy/README.md) is the documentation and teaching copy
of the same phases, with Red Hat's words behind each step. The playbooks run from the same mirroring bastion the [`oc-mirror-ansible/`](../oc-mirror-ansible/README.md) playbooks run on,
and with the same Vault-encrypted Red Hat pull secret. They are the "Ansible runs the retrofit and the
updates" part of the proxy approach ([`docs/SOLUTIONS.md`](../docs/SOLUTIONS.md), "What Ansible automates").

| | |
|---|---|
| Status | Written and tested offline against a stand-in cluster ([`tests/`](tests/)). Not yet run on a real cluster: the change is with security on the threat model, condition: applications cannot use the proxy by default |
| Runs on | The mirroring bastion: `oc` logged in as cluster-admin, `ansible-core` (2.15 or later), the Red Hat pull secret in `../oc-mirror-ansible/vars/redhat-pull-secret.json` (Ansible Vault). No collections beyond `ansible.builtin` |
| Red Hat's steps | KB ["Converting a disconnected cluster to a connected cluster"](https://access.redhat.com/solutions/6966995) (solution 6966995, Solution Verified, updated 29 October 2025): default OperatorHub sources back on, the mirrored CatalogSource and the ICSP removed, each Subscription re-pointed, the global pull secret updated; the community note adds the cluster-wide proxy and its reboots first. The runbook puts those steps in the order below |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/automation/run-flow.dark.png">
  <source srcset="docs/diagrams/automation/run-flow.light.png">
  <img alt="The Step 2 automation, end to end. On the mirroring bastion, Ansible runs one cluster at a time. The retrofit playbook runs phases 1 to 3 (backup, health check, pull secret, image allowlist; it stops before any change if the cluster is not healthy), then phase 4 in a window (the proxy CA appended once, the proxy object patched, waits for readiness, every pool and every operator; every node drains and reboots), then phases 6 and 7 (update checks from Red Hat, the stock catalog, each Subscription set to Manual and moved; a ResolutionFailed is named and left on the mirror). The verify playbook runs tests 1 to 10 in a plain namespace and writes the evidence file; a proxy variable in a workload pod fails it. The update playbook runs the first connected update and stops unless the release signature was verified. The remove-mirror playbook, in a window, takes out the mirror sets, catalogs, Update Service, login, CA key and allowlist entry, refusing while a Subscription still uses a mirrored source. Then verify again, and every later hop is the update playbook alone, with no mirror, no sync and no local Update Service. The right column shows the cluster after each run and the node effect." src="docs/diagrams/automation/run-flow.light.png">
</picture>

*One cluster, end to end: the runs in the runbook's order, what stops each one, and the cluster after it.
Source: [`docs/diagrams/automation/source.html`](docs/diagrams/automation/source.html), rendered with diagram-kit.*

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/automation/update-flow.dark.png">
  <source srcset="docs/diagrams/automation/update-flow.light.png">
  <img alt="One update hop under the proxy approach. On the bastion, in a change window, update-playbook runs for one cluster: health check and no local Update Service in spec.upstream, else it stops with nothing started; the channel change when moving to 4.20, with RetrievedUpdates true, else stop and fix the allowlist or the CA; a recommended version from availableUpdates, else refused; then oc adm upgrade and the wait for a Completed history entry whose signature was verified, else stop before the next hop. The cluster's CVO then reads the graph from api.openshift.com, pulls the release by digest from quay.io and checks the signature with built-in keys; operators and pools roll, control plane then workers, CRI-O pulling through the proxy within the allowlist. All of it reaches Red Hat through the enterprise proxy with HTTP CONNECT on 443 to the documented hosts only. Back on the bastion: every operator and pool checked, the verify playbook writes the evidence file, and the next hop is the same run, 4.18 to 4.19 to 4.20 and later 4.22, with nothing to mirror first." src="docs/diagrams/automation/update-flow.light.png">
</picture>

*One update hop once the conversion is done: the update playbook on the bastion, the cluster's own update
machinery through the proxy, and the evidence file afterwards. No sync and nothing to mirror first.*

## The four playbooks

| Playbook | Runbook phases | Node effect | What it does |
|---|---|---|---|
| `retrofit-playbook.yml` | 1 to 7 | phase 4 drains and reboots every node; 2, 3, 6, 7 touch no node | Backs up every object it changes, refuses an unhealthy cluster, merges the Red Hat pull secret beside the mirror login, replaces `blockedRegistries` with `allowedRegistries`, sets the cluster-wide proxy with its CA, clears `spec.upstream`, turns on the approved default catalog and moves each Subscription to it |
| `update-playbook.yml` | 8 (and every later hop) | an update | Changes the channel if asked, starts `oc adm upgrade --to=<version>` (or `--to-latest`), waits for `status.history[0]` to be `Completed`, and stops if `verified` is not `true` (control C4 of the threat model) |
| `remove-mirror-playbook.yml` | 9 | the MCO drains, and by the docs reboots, every node | Only after a verified connected update: deletes the IDMS, ITMS and ICSP objects, the mirrored CatalogSources and the local Update Service, and takes the mirror out of `allowedRegistries`, the CA ConfigMap and the pull secret. Checks a node's `registries.conf` lists no mirror |
| `verify-playbook.yml` | Verify, tests 1 to 10 | creates and removes a test namespace | Runs the runbook's Verify table and writes the evidence file for security. Test 7 needs phase 5 and test 11 is the proxy log review: both stay manual |

Each phase of `retrofit-playbook.yml` is a tag, so the runbook's order and its windows are kept. Phase 1
(`backup`, `check`) runs every time. Phases 4 and 5 (`proxy`, `egress-firewall`) run only when named.

## Running it

```bash
cd ~/openshift-upgrade/enterprise-proxy-ansible
cp vars/cluster.yml.example vars/cluster-prod1.yml     # one file per cluster, kept out of Git
vi vars/cluster-prod1.yml                              # noProxy, allowed_registries, the proxy URL and CA, the catalog names
oc login ...                                           # cluster-admin on the cluster being converted

# Phases 1 to 3 (no node effect): back up, check, pull secret, image policy
ansible-playbook retrofit-playbook.yml -e @vars/cluster-prod1.yml --tags pull-secret,image-policy

# Phase 4, in a maintenance window: the proxy. Every node drains and reboots, pool by pool
ansible-playbook retrofit-playbook.yml -e @vars/cluster-prod1.yml --tags proxy

# Phases 6 and 7 (no node effect): the update graph and the catalogs from Red Hat
ansible-playbook retrofit-playbook.yml -e @vars/cluster-prod1.yml --tags update-service,catalogs
ansible-playbook verify-playbook.yml   -e @vars/cluster-prod1.yml          # evidence, first pass

# Phase 8: the first connected update, with the mirror still in place as the fallback
ansible-playbook update-playbook.yml   -e @vars/cluster-prod1.yml -e update_to=4.18.30   # a version from the recommended list

# Phase 9, in a maintenance window: remove the mirror
ansible-playbook remove-mirror-playbook.yml -e @vars/cluster-prod1.yml
ansible-playbook verify-playbook.yml        -e @vars/cluster-prod1.yml     # evidence, second pass

# Later hops run the same way, with no mirror and no sync
ansible-playbook update-playbook.yml -e @vars/cluster-prod1.yml -e update_channel=eus-4.20 -e update_to=4.20.<z>
```

The pull secret is Vault-encrypted in the mirroring playbooks' folder, so add
`--vault-password-file ~/.vault-pass-oc-mirror` if `pull_secret_file` points at the encrypted copy, or decrypt
it to a private file first and point `pull_secret_file` there.

## What the playbooks protect

- **Nothing runs on an unhealthy cluster.** Phase 1 stops when a ClusterOperator is not Available or is
  Progressing or Degraded, when a pool is paused, updating or degraded, or when ClusterVersion is progressing.
  It lists the PodDisruptionBudgets with no disruptions allowed, which would stall the drain in phase 4.
- **Everything changed is backed up first**, as YAML under `backup_root/<cluster>-<date>/`, mode 0700,
  the pull secret copy 0600, on the bastion only.
- **Credentials never reach a log.** The pull-secret tasks run with `no_log`; the merged file is written
  0600 under the backup folder's `work/` and removed in an `always` block, on failure too. The playbooks
  print the registry names in the secret, never the tokens. The tests grep every run's output for the
  fixture tokens.
- **Order is enforced.** `update-playbook.yml` refuses to run while `spec.upstream` still points at the
  local Update Service; `remove-mirror-playbook.yml` refuses until `status.history[0]` is `Completed` and
  `verified`, and while any Subscription still uses a mirrored CatalogSource.
- **The proxy CA is added, not replaced.** If `user-ca-bundle` exists (the mirror CA is often in it), the
  proxy CA is appended once; a second run changes nothing.
- **Subscriptions move safely.** `installPlanApproval` is set to `Manual` before a Subscription is moved
  (the stock catalog may hold newer versions than the mirror), its channel is kept, and a `ResolutionFailed`
  state is reported with the Subscription's name so it can be left on the mirrored source and raised.
- **The signature check is a gate.** After each update the playbook asserts `status.history[0].verified`
  is `true`; a false value stops everything before the next hop.

## Variables

All in [`vars/cluster.yml.example`](vars/cluster.yml.example), one block per phase, with the runbook's
values as examples. The ones that need thought per cluster: `no_proxy` (every internal name by name, plus
`.apps.<cluster>.<domain>`), `allowed_registries` (the phase 1 inventory prints what running pods use),
`proxy_ca_file` (empty if a public CA signs the proxy), `mirrored_catalog_sources` and
`default_catalog_sources` (`certified-operators` only with partner operators), and `telemetry_enabled` (D3).
Shared internals (`oc`, the backup folder, the poll interval and retry counts) are in `vars/common.yml`.

## Tests

```bash
source ../.venv/bin/activate      # ansible-core, ansible-lint, yamllint
tests/test.sh
```

`tests/bin/oc` is a stand-in for `oc` that keeps a disconnected cluster in a JSON file
(`tests/fixtures/state.json`: `blockedRegistries`, a local Update Service in `spec.upstream`, a mirrored
CatalogSource with two Subscriptions, IDMS and ITMS objects, a pull secret with the mirror login) and answers
the commands the playbooks run. `tests/test.sh` runs the lints and the syntax check, then the four playbooks in
the runbook's order and checks the resulting cluster state, the recorded `oc` calls, the backups and that no
token appears in any output. It also checks the refusals: a degraded operator, an operator the stock catalog
lacks, an update before phase 6, a mirror removal while a Subscription still uses the mirrored catalog, and a
workload pod that receives proxy variables (test 6, the threat model's condition). The pull secret in
`tests/fixtures/` holds made-up tokens.

The stand-in is not a cluster: it does not drain nodes, and it answers every `oc debug` the way a healthy
node would. The first run on a real cluster is the lab cluster, with the runbook open beside it.
