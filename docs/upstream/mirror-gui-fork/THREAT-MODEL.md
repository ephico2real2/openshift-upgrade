# Threat model: mirror-gui on a mirroring bastion

How `openshift/mirror-gui` (upstream commit `3cec34f`) is exposed when it runs on one of our
mirroring bastions, the three threats behind the issues in [`../mirror-gui-issues.md`](../mirror-gui-issues.md),
and what the fork's branch `fix/tls-deps-bind` changes. Scope: the deployment we would use, a shared
RHEL 9 bastion that reaches Red Hat through the enterprise proxy and carries archives to the
disconnected side.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/threat-model/threat-model.dark.png">
  <source srcset="diagrams/threat-model/threat-model.light.png">
  <img alt="Threat model of mirror-gui on a mirroring bastion. Red Hat's registries on the internet are reached through the enterprise proxy over TLS. Threat T1 is an interception on that path, which upstream mirror-gui cannot detect because it always passes tls-verify=false to oc-mirror; mitigation M1 verifies source TLS by default. On the bastion, the mirror-gui container holds the unauthenticated API, the pull secret, oc-mirror, the catalog metadata and the mirror archive. Threat T3: upstream publishes port 3000 on every interface, so other hosts on the corporate network can read or replace the pull secret and start runs; mitigation M3 publishes on 127.0.0.1 only, and the admin reaches it through an SSH tunnel. Residual risk: any local user on the bastion can still reach 127.0.0.1:3000, because the API has no authentication. Threat T2: the operator list misses dependencies, so the archive carried to the disconnected registry is incomplete and the install fails on the cluster; mitigation M2 resolves dependencies per channel, transitively, including required APIs, and warns about the ones it cannot resolve." src="diagrams/threat-model/threat-model.light.png">
</picture>

*Data flows, trust boundaries (red dashed), threats T1–T3 in upstream and mitigations M1–M3 on the fork.*

## Assets and trust boundaries

| Asset | Where | Why it matters |
|---|---|---|
| Red Hat pull secret | mirror-gui container, served by `GET /api/pull-secret/content` | Grants access to Red Hat's registries under our account |
| Mirror archive and cache | `/data` on the bastion | Becomes the content of the disconnected registries and clusters |
| Operator list (ImageSetConfiguration) | Built in the UI from the catalog metadata | Decides what the disconnected clusters can install |

| Boundary | Crossed by |
|---|---|
| Internet ↔ bastion (through the enterprise proxy) | oc-mirror pulling from `registry.redhat.io` and `quay.io` over TLS |
| Corporate network ↔ bastion | Anyone reaching the bastion's port 3000 (upstream) |
| Admin workstation ↔ bastion | The admin's SSH tunnel (after M3) |
| Bastion ↔ disconnected side | The archive, carried across and pushed with disk-to-mirror |

## Threats and mitigations

| # | Threat (STRIDE) | Upstream `3cec34f` | Mitigation on the fork | Residual risk |
|---|---|---|---|---|
| T1 | Tampering and information disclosure: content intercepted or altered on the TLS path to Red Hat | Every run passes `--src-tls-verify=false --dest-tls-verify=false`; no setting to change it | **M1** (`9d608b6`): source TLS verified by default; `skipSourceTlsVerify` is an explicit per-run opt-out with a warning | A user can still opt out per run. Release signature checks cover release images, not every operator image |
| T2 | Denial of service on the disconnected side: an incomplete operator set, found only when the install fails | Only package dependencies, only the default channel head, one level, guessed channels | **M2** (`4f0fb49`): per channel, transitive, required APIs resolved to their provider, unresolved APIs shown as a warning | APIs provided by several or no packages still need a person to decide; the lab install remains the proof |
| T3 | Information disclosure and elevation of privilege: anyone on the network reads or replaces the pull secret and starts runs | API has no login; port published on every interface (`0.0.0.0`) | **M3** (`3fdcae0`, `f8d3b24`): published on `127.0.0.1` by default; any other address prints a warning; SSH tunnel documented | **Any local user on the bastion** can still reach `127.0.0.1:3000`. Run it on a single-user bastion or under a dedicated user; long term, the API needs authentication |

## What we do on our bastions

- Run mirror-gui for planning only, never for mirror runs; the playbooks run the mirrors
  ([catalog guide, Step 2](../../../oc-mirror-ansible/docs/catalog-mirroring-guide.md#optional-plan-the-operator-list-with-mirror-gui)).
- Use the fork's branch until upstream takes the fixes; leave `skipSourceTlsVerify` off.
- Keep port 3000 closed in firewalld, run it rootless, reach it only through an SSH tunnel, and stop
  it when done (`./local-build.sh --stop`).
- Treat every account that can log in to the bastion as able to read the pull secret while it runs.

## Diagram source

[`diagrams/threat-model/source.html`](diagrams/threat-model/source.html), rendered with
[diagram-kit](https://github.com/ephico2real2/diagram-kit) (installation in `docs/PROBLEM-STATEMENT.md`,
Diagram sources):

```bash
.venv/bin/diagram-render docs/upstream/mirror-gui-fork/diagrams/threat-model/source.html \
  docs/upstream/mirror-gui-fork/diagrams/threat-model threat-model
```
