# Design decisions: how our OpenShift clusters reach Red Hat to stay current

| | |
|---|---|
| Researched | 2026-09-25, against OpenShift 4.22 docs and `release-4.22` product source |
| Hosts | Two mirroring bastions and three registries (lab, DC1, DC2) on RHEL 9, replacing the three old mirror registries 1.x: [`PREREQUISITES.md`](PREREQUISITES.md); all three steps side by side: [`SOLUTIONS.md`](SOLUTIONS.md) |
| Evidence | [`openshift-update-egress.html`](openshift-update-egress.html) (section names are cited below as *§ name*); the problem is stated in [`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md) |
| Status | **No decision is ratified yet.** The team stated its position on D1 on 2026-10-05; it still depends on security approval. Every other entry in [Decisions](#decisions) is a recommendation waiting on the input named beside it. |

Version-specific facts here were true on 2026-09-25. Re-check them if a newer 4.x has shipped.

## Problem

Our clusters run disconnected, so every update starts with a manual mirror. We want a partially
connected design that lets us update on a regular schedule.

### Steps

| Step | What | Status | Here |
|---|---|---|---|
| 1 | Refine the current process (the manual sync) | **Done, 2026-10-07:** oc-mirror v2 run from Ansible playbooks, still started by hand | [`oc-mirror-ansible/`](../oc-mirror-ansible/README.md) |
| 2 | Refine the enterprise proxy strategy | Runbook written, 2026-10-07 | Option 1 below; [`enterprise-proxy/`](enterprise-proxy/README.md) |
| 3 | Build a full Red Hat Quay registry on-prem | Design written, 2026-10-07 | Option 2 below; [`quay-onprem/`](quay-onprem/README.md) |

Step 1 keeps the manual sync but makes it repeatable. It runs on a mirroring bastion in each datacenter and fills three new mirror registries ([`PREREQUISITES.md`](PREREQUISITES.md)). Its playbooks are also a starting point for the scheduled oc-mirror v2 job that Options 2 and 3 need.

Where we are (stated by the team on 2026-10-05): OpenShift 4.18 on the EUS channel, well behind.
The plan is 4.18 to 4.20, then 4.20 to 4.22. Measured that day: 4.18 maintenance ended on
2026-08-25 and its EUS term ends on 2027-02-25; the `eus-4.20` channel recommends
4.18.54 → 4.19.47 → 4.20.39; every edge from 4.21 into 4.22 in `eus-4.22` is conditional. Details
and queries are in [`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md).

## Options on the table

| | Design | Cluster egress | What we run |
|---|---|---|---|
| **1** | Allowlist Red Hat hosts + cluster-wide proxy | Images, update graph and signatures, from every node through the proxy | An HA egress proxy |
| **2** (as first written) | Internal Quay filled by Quay "image sync", two-headed DNS, OSUS | None | HA Quay, OSUS, split DNS |
| **2** (as documented) | Internal Quay filled by oc-mirror v2, OSUS | None | Mirror host, HA Quay, OSUS |
| **3** (added by the research) | Graph and signatures from Red Hat through the proxy; images from our mirror registries through IDMS, filled by a scheduled oc-mirror v2 job | Update graph and signatures only | Mirror host, our current registry, proxy |

Every option opens `quay.io` and `registry.redhat.io` at the firewall. They differ in which machines
use that opening: every cluster node (Option 1) or one mirror host (Options 2 and 3). *§ What the
research found*

## Decisions

| ID | Question | Recommendation | Waiting on |
|---|---|---|---|
| D1 | Which design do we build? | **Team position, 2026-10-05, refined 2026-10-09:** two approaches. Preferred: Option 1, the proxy approach, which other teams (VMware, TKG) already update through. Fallback: the mirror approach automated, the Ansible playbooks on a schedule into the new registries, with Option 2's Red Hat Quay on-prem as that registry once built | Security's answer on which machines may reach Red Hat; for the alternative, a Red Hat Consulting engagement and a Quay specialist |
| D2 | Filtered catalog (model A) or allowlist on the stock catalog (model B)? | Model A, keeping a mirror registry for the catalog image alone | D1 (the registry product is answered: mirror registry for Red Hat OpenShift, [`PREREQUISITES.md`](PREREQUISITES.md)) |
| D3 | Keep telemetry and Insights on? | Security team's call | Security |
| D4 | Will the proxy decrypt traffic to Red Hat hosts? | **Answered 2026-10-09: yes.** The proxy re-signs with the enterprise CA, which every node trusts; the same CA goes into `trustedCA`; `sso.redhat.com` excluded from re-encryption | Red Hat's support position on inspecting `quay.io` and `registry.redhat.io` (still unverified) |
| D5 | How often do we update? | Monthly z-stream window; EUS-to-EUS minors for production, which matches the team's 4.18 → 4.20 → 4.22 plan | Team agreement on the z-stream window |

### D1 · Which design

**Team position (2026-10-05).** Preferred: Option 1, a direct enterprise proxy with only Red Hat's
documented hosts allowed and no two-headed DNS. Alternative: Option 2, a full Red Hat Quay registry
on-prem, built with Red Hat Consulting and a Quay specialist. Operator catalogs have to be accounted
for in both (D2).

How that position sits against the research of 2026-09-25:

- It matches the research on Option 1, including the DNS point.
- For Option 2, the research found that the registry should be filled by oc-mirror v2 with an
  `ImageSetConfiguration`, not by Quay repository mirroring, and that Quay needs no two-headed DNS
  either.
- The research found no Red Hat document that requires Consulting for Quay. Engaging them is the
  team's choice.
- The research recommended Option 3 as the fallback when security approves only update metadata
  from the clusters. The team's position names Option 2 as the fallback instead. Option 3 stays on
  the table below; Red Hat does not document it.

**Refined (2026-10-09).** The recommendation is two-fold ([`SOLUTIONS.md`](SOLUTIONS.md),
Recommendation), two approaches rather than steps in sequence: the proxy approach first, since other
teams already update VMware and Tanzu Kubernetes Grid through the same enterprise proxy; and, as the
fallback, the mirror approach automated, the Ansible playbooks on a schedule into the new registries,
with Quay on-prem as that registry once built.

The choice turns on one security answer: which machines may reach Red Hat through the proxy.

- **Node egress to the four host groups is approved** → Option 1. It uses only documented
  configuration and needs no mirror to run.
- **Only `api.openshift.com` and `mirror.openshift.com` are approved from the clusters** → Option 3,
  plus a CI gate so a cluster is only told to go to versions already mirrored. Red Hat does not
  document this combination; confirm it in a support case before adopting it.
- **No cluster egress at all** → Option 2 in its documented form: oc-mirror v2, not Quay repository
  mirroring.

*§ Decisions, D1*

### D2 · Catalog model

- Model A (filtered catalog) shows developers only what they may install. It needs a registry to
  host the catalog image, and every node must be able to pull it.
- Model B (allowlist on the stock `redhat-operators` catalog) needs no registry. The full catalog
  stays visible in the console, and every dependency has to be listed by hand.

Recommendation: model A, with a mirror registry kept for the catalog image alone (the lab and production mirror registries in [`PREREQUISITES.md`](PREREQUISITES.md)). That leaves the
admission policy one prefix to check. *§ Decisions, D2; § Limiting operator catalogs*

### D3 · Telemetry

The firewall doc lists the telemetry hosts only "if you do not disable Telemetry"; updates do not
use them. Turning telemetry off removes three hosts from the approval request and costs us Insights
recommendations. It can be turned on later without touching nodes. *§ Decisions, D3*

### D4 · TLS interception

**Answered 2026-10-09:** the enterprise proxy inspects TLS and re-signs it with the enterprise CA,
and every OpenShift node already carries the enterprise trust bundle. The CA must also be in
`user-ca-bundle` (`trustedCA` on `proxy/cluster`) so platform components trust it, and Red Hat asks
that `sso.redhat.com` is not re-encrypted. Inspection is also what makes filtering `quay.io` by
repository possible at the network layer. Red Hat's support position on inspecting `quay.io` and
`registry.redhat.io` traffic could not be verified. Payload integrity does not depend on the proxy:
the CVO checks GPG signatures and CRI-O checks sigstore signatures. *§ Decisions, D4*

### D5 · Cadence

Z-streams for the newest minor ship weekly. Full support lasts 6 months, or until 90 days after the
next minor's GA, whichever is later; maintenance runs to 18 months. Even minors get EUS.
Control-plane-only updates work between even minors. *§ Decisions, D5*

## What the research changed in the original plan

These are findings, not choices. Each one replaced an assumption in the plan as first written.

| Assumption in the plan | Finding | Where |
|---|---|---|
| Option 1 needs no two-headed DNS | Holds, with conditions: add `.apps.<cluster>.<domain>` to `noProxy` (the authentication and console operators probe their routes through the proxy) and give NTP an internal source | *§ Your plan, checked line by line*, row a |
| Option 2 needs two-headed DNS | Does not hold. Quay repository mirrors and oc-mirror v2 both accept a proxy setting | row a1 |
| Quay "image sync" mirrors OpenShift releases and catalogs | Does not hold. It copies tags by glob, one repository at a time, with no logic for release payloads, catalog `relatedImages`, signatures or the update graph. The 4.22 docs name oc-mirror v2 | row a2 |
| Option 2 means a new cluster | No document requires one. Quay runs standalone HA on RHEL or through the Quay Operator on an existing cluster | row "new setup, new cluster" |
| Option 2 may need Red Hat Consulting | Unverified. The docs say to contact sales or Support; none says Consulting is required | row "may need Red Hat Consulting" |
| "Limit the catalog via Git" | Git is where changes are reviewed; it enforces nothing. Default RBAC already stops namespace admins from adding catalogs. `disableAllDefaultSources` does not touch OLM v1 ClusterCatalogs. Only a ValidatingAdmissionPolicy also binds cluster-admins and Argo CD | rows c and d; *§ Limiting operator catalogs* |
| "Set up the OpenShift console" (Option 2, step e) | Not researched: the plan does not say which console work is meant | row e |

Two further findings shape the rollout order:

- Enabling the cluster-wide proxy drains and reboots every node once, and again whenever
  `httpProxy`, `httpsProxy` or `noProxy` change. Updating the pull secret touches no nodes.
  *§ What each change does to the nodes*
- Since 4.21, release images served from a mirror need their sigstore signatures mirrored too, or
  node updates stop. *§ What the research found*

## Rollout order for Option 1

Per cluster, lower environments first. Changes that touch no nodes go first, the proxy change gets
its own window, and the mirror sets come out only after a connected update has succeeded.

| Phase | What | Node effect |
|---|---|---|
| 0 · Approve | Security sign-off, HA egress proxy, Registry Service Account, support case opened | None |
| 1 · Prepare | Red Hat credentials in the global pull secret; `allowedRegistries`; catalog admission policy in `Warn, Audit` | CRI-O reload only |
| 2 · Proxy | Proxy object with `noProxy`, `trustedCA`, `readinessEndpoints` | Drain + reboot, every node |
| 3 · Update checks | Clear `spec.upstream`; set the channel | None |
| 4 · Catalogs | Default sources off, default ClusterCatalogs `Unavailable`, Git-owned Subscriptions with Manual approval, admission policy to `Deny` | None |
| 5 · First update | Update one z-stream, then remove the mirror sets | Removing mirror sets: drain + CRI-O reload |
| 6 · Cadence | Z-streams on a fixed schedule | Per update |

Completion criteria for each phase are in *§ Rollout plan for Option 1*. The host allowlist is in
*§ Option 1 in detail*, and the risk-to-control table for the security request is in *§ Security
controls for the approval request*.

## Catalog admission policies

The policies and their test suites are in [`catalog-policies/`](catalog-policies/). Outcomes below
are the ones the 2026-09-25 session recorded.

| Policy file | Covers | Recorded result |
|---|---|---|
| `vap-olm-catalogs.yaml` | Model A: CatalogSources, Subscriptions, InstallPlan approval, OLM v1 ClusterCatalogs | 19 of 19 cases as expected on Kubernetes 1.31.14 and 1.37.0 (kind) |
| `vap-olm-package-allowlist.yaml` | Model B: package and channel allowlist on the stock catalog | 8 of 8 cases as expected on Kubernetes 1.31.14 and 1.37.0 (kind) |
| `gatekeeper-olm-catalogs.yaml` | Gatekeeper equivalent, CatalogSource only | 8 of 8 with `gator verify` v3.23.1, offline |
| `kyverno-olm-catalogs.yaml` | Kyverno equivalent, CatalogSource only | 8 of 8 fixtures as expected with the `kyverno` CLI v1.19.1, offline |

Limits of that testing:

- None of the policies has run on a live OpenShift cluster.
- `matrix.sh` names Kubernetes 1.35 as the OpenShift 4.22 base. The final 19-case suite has no
  recorded run on 1.35.
- The in-cluster Kyverno and Gatekeeper run (`engines.sh`) was stopped before it finished; those two
  engines were checked with their offline CLIs only.
- `mirror.corp.example.com/olm/` is a placeholder prefix.

## Still open

For our team:

1. Platform and number of clusters, and which 4.18 release each one is on (version answered on 2026-10-05: 4.18, EUS channel)
2. Whether we have OpenShift Platform Plus (it includes Quay and ACM)
3. ~~Which registry product we mirror into today~~ Answered 2026-10-07: three old mirror registries for Red Hat OpenShift 1.x, each over three years old; they are replaced one for one by three new 2.0.x registries ([`PREREQUISITES.md`](PREREQUISITES.md))
4. Whether OpenShift GitOps or ACM is already running
5. What "set up the OpenShift console" in Option 2 refers to

For a Red Hat support case:

1. Is Option 3 supported: graph from `api.openshift.com` through the proxy, images from an IDMS mirror?
2. What is the support position on a TLS-intercepting proxy?
3. Do updates need `console.redhat.com` / `sso.redhat.com`, and does an on-premises cluster need
   `quayio-production-s3.s3.amazonaws.com`?
4. Does editing an IDMS drain only, or also reboot? The docs text and the MCO code disagree.
5. Is `allowedRegistries: quay.io/openshift-release-dev` enough for a connected cluster?
