# Keeping our OpenShift clusters current: the proxy approach, with the mirror as the fallback

| | |
|---|---|
| Date | 2026-10-07 |
| For | Platform team, security, management |
| Status | Step 1 is built. The platform owner decides, and the decision is the proxy approach; the change goes to security on the threat model with one condition: applications cannot use the proxy by default. Not yet approved |
| Prerequisites | Two mirroring bastions and three registries on RHEL 9: [`PREREQUISITES.md`](PREREQUISITES.md) |
| Technical detail | Step 1: [`oc-mirror-ansible/`](../oc-mirror-ansible/README.md). Step 2: [`enterprise-proxy/`](enterprise-proxy/README.md). Step 3, the fallback (its Quay variant): [`quay-onprem/`](quay-onprem/README.md). The problem: [`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md). The decisions: [`DESIGN-DECISIONS.md`](DESIGN-DECISIONS.md) |

## Summary

Our clusters run OpenShift 4.18.17 on the EUS channel and are well behind. Every update starts with
someone copying images and catalogs into our registry, and that copy has failed several times. The
plan is to move to 4.20 and then 4.22, which needs four release payloads plus catalogs for each minor.

This document presents three steps. Step 1 is done and keeps us moving now. The proxy approach
(Step 2) is the platform owner's decision for the long term; the mirror approach automated on a
schedule (Step 3's schedule, whatever the registry product) is the fallback only.

| # | What it is | Who copies the content | Cluster egress | Status |
|---|---|---|---|---|
| **1** | Our current process, modernised with Ansible and oc-mirror v2 | We do, from the mirroring bastion in each datacenter, each time we update | None | **Done**: playbooks and guides in Git |
| **2** | Clusters reach Red Hat through the enterprise proxy | Nobody: the cluster pulls what it needs | Red Hat hosts only, through the proxy | Runbook and threat model written; the change is with security |
| **3** | The mirror approach, automated: the Step 1 playbooks on a schedule into the new registries; Red Hat Quay on-prem would only change the registry product | A scheduled job, not a person | None | Fallback only; the Quay variant is designed, not built |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/three-steps/three-steps.dark.png">
  <source srcset="diagrams/three-steps/three-steps.light.png">
  <img alt="Three steps keep the clusters current. Step 1, built: a person runs the Ansible oc-mirror v2 playbooks on the mirroring bastion of each datacenter before each update, into the lab and production mirror registries, and the cluster stays disconnected with a local Update Service. Step 2, the platform owner's decision: every node reaches Red Hat's hosts through the enterprise proxy, with no mirror, no sync and no local Update Service, and Ansible runs the retrofit and the updates. Step 3, the fallback only: the same playbooks run on a schedule into the new registries and the cluster keeps no egress with a local Update Service; Red Hat Quay on-prem would only change the registry product. All three open the same Red Hat hosts and none needs two-headed DNS." src="diagrams/three-steps/three-steps.light.png">
</picture>

*Step 1 is built. Step 2 is the platform owner's decision; Step 3 is the fallback only. All three open
the same Red Hat hosts; they differ in which machines use them. No step needs two-headed DNS.*

```text
            STEP 1 (built)                 STEP 2 (the decision)                 STEP 3 (fallback only)
INSIDE      cluster: no egress, local OSUS cluster: Proxy CR, workloads blocked   cluster: no egress, local OSUS
            mirror registries: lab,DC1,DC2 enterprise proxy, Red Hat hosts only  mirror registries or Quay, HA
            bastion per datacenter, by hand no mirror host, registry or OSUS     bastion per datacenter, timer
EGRESS      one host, through the proxy    every node, through the proxy         one host, through the proxy
RED HAT     quay.io, registry.redhat.io, api.openshift.com, mirror.openshift.com
```

**The platform owner decides (position of 2026-10-05, refined 2026-10-09):** the proxy approach, with the
mirror approach, automated, as the fallback only. The change goes to security on the threat model
([`enterprise-proxy/THREAT-MODEL.md`](enterprise-proxy/THREAT-MODEL.md)) with one condition: consumers
and applications cannot use the proxy by default. With that met, we are good. The SMEs and the Product
Owner shape the direction of this platform offering; this is the SME's recommendation, from experience
and modern best practice. Ansible automates the upgrade in both cases: under the proxy option too, the
playbooks drive the retrofit and the updates themselves. The difference is the manual mirror, which
the proxy approach eliminates. We are not after two-headed DNS; we are after a sustainable way to update
as we grow. The disconnected setup was carried over from OpenShift 3.x, where the proxy setup was a mess;
on OpenShift 4.x the proxy is Red Hat's supported way for enterprise customers to take fixes as they ship, and
it keeps us ready for the growth that follows (OpenShift 5.x, for example).

## Where we are

| Fact | Value |
|---|---|
| Version and channel | 4.18.17 on `eus-4.18` |
| 4.18 support | Maintenance ended 25 August 2026; the EUS term ends 25 February 2027 |
| Target | 4.20 (EUS), then 4.22 (EUS). 4.22 reached GA on 9 June 2026 |
| Road | Control-plane-only EUS updates: 4.18 → 4.19 → 4.20, then 4.20 → 4.21 → 4.22 |
| Registries today | Three old **mirror registries for Red Hat OpenShift** 1.x (the trimmed-down, single-host Quay), each more than three years old: 1.0 to 1.3.x, Quay 3.6 to 3.8 |
| What each hop needs in a disconnected cluster | Its release payload (about 190 images), the update graph, the release signatures and, from 4.21, sigstore signatures; plus an operator catalog per minor |

Measurements and sources are in [`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md).

## Before any step: new hosts

The three old registries are replaced, not upgraded. Red Hat now ships mirror registry 2.0.x (Quay
3.12, SQLite instead of PostgreSQL) and documents an in-place upgrade only from 1.3; ours are older. We build new hosts
instead, all on RHEL 9 (RHEL 10 is not yet supported for the mirror registry or `oc-mirror`):

- **A mirroring bastion in each datacenter.** Every Ansible and oc-mirror command runs there, and
  only the bastions reach Red Hat, through the enterprise proxy.
- **Three registries:** a lab registry, where new content is tried first, and one production
  registry in each datacenter. Each is a fresh mirror registry 2.0.x install, filled again from
  Red Hat by oc-mirror v2.
- **The old registries** serve the clusters until each cluster has switched to its new registry
  (lab to lab, DC1 to DC1, DC2 to DC2), then they are retired. Meanwhile the bastions can also push v2 content into them, or into any existing
  registry, on a new path (e.g. `ocp4v2`), never into the path oc-mirror v1 filled.

Red Hat discourages using one mirror registry for several clusters and asks for mirror registries
to be highly available. If a production registry serves several clusters under the fallback, a highly
available registry (full Quay) is its registry product. Hosts, sizing, flows and the cluster cutover: [`PREREQUISITES.md`](PREREQUISITES.md).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/prerequisites/topology.dark.png">
  <source srcset="diagrams/prerequisites/topology.light.png">
  <img alt="Target layout. In datacenter 1 a mirroring bastion reaches Red Hat only through the enterprise proxy and pushes over TCP 8443 to two mirror registries: the lab registry and the datacenter 1 production registry. In datacenter 2 its own bastion does the same for the datacenter 2 production registry. Lab clusters pull from the lab registry and each datacenter's production clusters pull from their own registry. Three old 1.x mirror registries, one per role, keep serving until their clusters have switched, then they are retired; meanwhile each datacenter's bastion may also push the same content into them on a new path, never into the oc-mirror v1 path. All new hosts run RHEL 9." src="diagrams/prerequisites/topology.light.png">
</picture>

*Proposed layout: the bastions and registries are not built yet.*

```text
DC1: mirror-bastion-dc1 --push 8443--> registry-lab (lab clusters), registry-dc1 (production DC1)
DC2: mirror-bastion-dc2 --push 8443--> registry-dc2 (production DC2)
both bastions --443 via the enterprise proxy--> Red Hat; the three old 1.x registries may take pushes on a new path
(e.g. ocp4v2, never the v1 path) until they are retired after cutover
```

## Step 1: our current process, modernised with Ansible

**What it is.** The same model as today, the mirroring bastion in each datacenter copies Red Hat
content into the lab registry and that datacenter's production registry before each update, but run by Ansible playbooks around oc-mirror v2, the tool Red Hat documents for
disconnected mirroring from 4.18 to 4.22.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../oc-mirror-ansible/docs/diagrams/mirroring/run-flow.dark.png">
  <source srcset="../oc-mirror-ansible/docs/diagrams/mirroring/run-flow.light.png">
  <img alt="One Step 1 release run. On the mirroring bastion: start the playbook in tmux with the Vault password; it checks the Red Hat pull secret, writes a private auth file and renders the ImageSet. A dry-run lists what would be copied; anything in missing.txt is fixed first. The real run downloads into an archive on the bastion and then pushes that archive into the lab registry, later the production registry; it retries each image five times, then the whole run up to three more times two minutes apart, and the cache lets a rerun resume. The auth file is removed even when the run fails. Then verify the tags, the .sig tags and the cluster-resources folder. In the cluster's change window an admin trusts the registry CA, applies the renamed IDMS and ITMS, the signatures and CatalogSources, sets up the Update Service, and oc adm upgrade lists the target." src="../oc-mirror-ansible/docs/diagrams/mirroring/run-flow.light.png">
</picture>

*One Step 1 release run, as the playbooks and guide do it today. Red boxes are what stops a run and
what fixes it.*

```text
MIRRORING BASTION                                       CLUSTER, change window
1 ansible-playbook in tmux, Vault password              7 registry login + CA trust
2 check pull secret (quay.io, registry.redhat.io)       8 apply cluster-resources (IDMS/ITMS renamed per run,
3 dry-run: mapping.txt; fix anything in missing.txt       signature ConfigMap, CatalogSources)
4 download (m2d) + cache, push (d2m) per registry   9 Update Service, spec.upstream, restart on new graph
5 auth file removed, even on failure                    10 oc adm upgrade lists the target
6 verify tags, .sig tags, cluster-resources/  --hand over-->
```

**What changed compared with the manual process:**

- **Repeatable runs:** the release images, the update graph and the Update Service operator come
  from one playbook; operator catalogs from a second, one catalog group and OpenShift version
  (`v4.18`, `v4.20`, …) per run.
- **Secrets in Ansible Vault:** the Red Hat pull secret and the registry login are encrypted at rest
  and never written in plain text to the playbook folder.
- **The corporate proxy on the bastions only:** the clusters stay disconnected.
- **Fewer failed syncs:** a dry-run first to size the run, retries and longer timeouts for the
  failures we saw, and a persistent cache: each bastion downloads to disk once (oc-mirror's
  mirror-to-disk), so a failed run resumes and later runs fetch only what changed, then pushes the
  same archive into lab and production (disk-to-mirror).
- **The whole road at once:** the playbooks can mirror 4.18 → 4.20 → 4.22 back to back, before any
  cluster updates, using the shortest path in each EUS channel.
- **A local OpenShift Update Service:** the clusters see the same recommended update paths as a
  connected cluster.
- **Signatures kept:** release runs keep the sigstore signatures that 4.21 and later require.
- **Step-by-step guides:** written for someone doing it the first time.

**What it doesn't change.** We still mirror everything ourselves. Each update waits until a person
has run the sync and applied its output to the cluster. When a sync fails, the update slips. The
catalog list has to be maintained by hand per version.

**Use it for:** the mirror as today, until each cluster is retrofitted. Under the proxy approach the
same playbooks run the retrofit and the hops; under the fallback they run the mirror on a schedule
(Step 3).

Detail: [`oc-mirror-ansible/README.md`](../oc-mirror-ansible/README.md), with the release and catalog guides.

## Step 2: the clusters reach Red Hat through the enterprise proxy

**What it is.** Each cluster's built-in proxy setting (the `Proxy` resource) sends the platform's
traffic to our enterprise proxy, which allows only the Red Hat hosts in Red Hat's firewall
documentation. The cluster then gets images, the update graph, signatures and operator catalogs the
way a connected cluster does. There is no mirror, no sync and no local Update Service.

**How an existing cluster gets there.** The runbook converts a running disconnected cluster in ten
phases, ordered so that changes that touch no nodes go first:

1. Approve the host list, set up the firewall and an HA proxy, and get Red Hat credentials.
2. Back up every object the runbook changes; inventory the internal services the platform uses.
3. Add Red Hat's pull secret to the cluster's global pull secret. No node effect.
4. Limit which registries and repositories any pod may pull from. CRI-O reload only.
5. Turn on the cluster-wide proxy. **Every node drains and reboots once**: a maintenance window.
6. Block application pods from the proxy, so only platform components use it.
7. Point update checks back at Red Hat.
8. Move operator subscriptions to Red Hat's catalog.
9. Run one update with the old mirror still in place, as a safety net.
10. Remove the mirror configuration and the local Update Service. Another drain.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/three-steps/retrofit.dark.png">
  <source srcset="diagrams/three-steps/retrofit.light.png">
  <img alt="The Step 2 runbook converts a disconnected cluster in ten phases. Phases 0 to 3 touch no nodes beyond a CRI-O reload: approval, backup, the Red Hat pull secret and the image allowlist. Phase 4 turns on the cluster-wide proxy and drains and reboots every node. Phases 5 to 7 lock workloads out of the proxy, point update checks at Red Hat and move the operator catalogs, with no node effect. Phase 8 runs one update with the mirror still in place, and only then phase 9 removes the mirror, which drains the nodes again." src="diagrams/three-steps/retrofit.light.png">
</picture>

*The proposed retrofit, phase by phase, with what each phase does to the nodes. The numbered list
above is the same order.*

**What going direct gives us, beyond removing the sync:**

| Advantage | Why |
|---|---|
| Updates arrive when Red Hat ships them | Z-streams for the newest minor ship weekly. A cluster can take a security fix the day it is published, not after a mirror run has succeeded |
| Live upgrade guidance | The cluster reads its update recommendations from `api.openshift.com`, including Red Hat's known-issue risks on conditional upgrade paths, as soon as they are published. A local Update Service only knows what the last sync brought |
| No signature mirroring | From 4.21 release images must be signed. A connected cluster reads the signatures from Red Hat; a disconnected one needs them mirrored, plus the `ack-4.20-sigstore-in-4.21` acknowledgment before 4.21 |
| Current catalogs, still under our control | Approved operators come current from Red Hat, with no mirroring and no hand-listed dependencies (oc-mirror v2 does not infer them). What developers see is still only what we put in the catalog: a filtered catalog (model A) or an allowlist on the stock one (model B), enforced by the admission policies in [`catalog-policies/`](catalog-policies/) (DESIGN-DECISIONS, D2) |
| Less to run and size | No mirror registries to keep highly available, no 2 TB caches, no oc-mirror version to track, none of its known failure modes (Red Hat KBs 7130341, 7139982, 7128745) |
| Fewer node drains later | No IDMS/ITMS/ICSP to create or delete at each cutover; deleting them drains the nodes |
| Red Hat's standard configuration | The connected cluster-wide proxy is the documented, most common setup, so support cases start from known ground |
| Optional, if security agrees | Insights recommendations and telemetry give Red Hat Support proactive alerts and cluster data. Off unless enabled; updates do not need them |

The costs are in the runbook: an HA proxy, security's approval of the change, one reboot of every
node when the proxy goes on, and one drain when the mirror objects are removed.

**A common misconception: "our clusters cannot use a proxy."** They can, and Red Hat documents it
as a standard configuration, both when a cluster is installed and on a running one: "Production
environments can deny direct access to the internet and instead have an HTTP or HTTPS proxy
available. You can configure a new OpenShift Container Platform cluster to use a proxy by
configuring the proxy settings in the `install-config.yaml` file"
[R4] (for existing clusters, [R6]). The proxy serves the platform only (below), allows only
Red Hat's documented hosts, and needs no two-headed DNS.

**Syncing and the proxy bring the same content from the same trusted partner.** We already trust
Red Hat's content: today we copy it into our registries and run it. Going through the proxy changes
only how it travels, not what arrives or how it is checked.

| | Syncing (Step 1, Step 3) | Proxy (Step 2) |
|---|---|---|
| Where it comes from | Red Hat's registries, through the enterprise proxy, to a bastion | Red Hat's registries, through the enterprise proxy, to the nodes |
| What arrives | The release images, by their SHA digests | The same images, by the same digests |
| How it is checked | The cluster validates Red Hat's signed statements with built-in public keys; from 4.21, Sigstore signatures as well | The same checks, against Red Hat directly |
| Hosts opened at the firewall | `quay.io`, `registry.redhat.io`, `api.openshift.com`, `mirror.openshift.com` | The same hosts |
| Delay before a cluster can use it | Until the next successful sync | None |

Red Hat: "Red Hat publishes cryptographically-signed statements about published release images at
predefined locations by using image SHA digests as unique and immutable release image identifiers.
The CVO utilizes a list of built-in public keys to validate the presence and signatures of the
statement matching the checked release image" [R5]. The
signature check is the same in both designs; syncing adds a copy and a wait.

**Syncing leaves us at a disadvantage when Red Hat fixes a bug or a vulnerability.** The fix is
published the same day either way. A synced cluster can take it only after someone has mirrored it
and the run has succeeded; a proxied cluster can take it in the next change window, after the lab.
We still decide when each cluster updates; the proxy removes the wait, not the control.

**What the proxy unlocks:**

| Area | With syncing | With the proxy |
|---|---|---|
| Keeping up with updates | Each z-stream (weekly for the newest minor) waits for a mirror run; 4.18 fixes keep shipping (156 CVEs in 4.18 advisories so far in 2026) | Every z-stream and its upgrade guidance are available when Red Hat publishes them |
| Building new clusters | A mirror with the target release first, then a disconnected install pointing at it | `install-config.yaml` names the proxy; the installer pulls the current release from Red Hat |
| New platform features and operators | Each new operator, and every dependency, mirrored by hand before anyone can try it | Available as soon as Red Hat ships it; we still choose what the catalog shows |

**Does the cluster-wide proxy open every namespace to the internet? No.** Red Hat, in the 4.18 and
4.22 docs alike: "The system-wide proxy affects system components only, not user workloads" [R1].
Application pods get no proxy settings, and the firewall still lets nothing out directly. Even
platform components reach only what the proxy allows, and our allowlist is Red Hat's documented
hosts and nothing else [R7].

The threat model of an update through the proxy, with a diagram, is in
[`enterprise-proxy/THREAT-MODEL.md`](enterprise-proxy/THREAT-MODEL.md).

**Our guarantee: the platform's proxy setting does not reach non-platform applications.** Nothing in
the platform writes proxy variables into an application pod [R1]. Application teams are already
allowed to set a proxy in their own deployments; a team that does so makes a deliberate choice under
our existing policy, and the platform never makes it for them. That is not a gap the Proxy object
introduces, so the runbook does not try to block it (its phase 5 is optional, see the runbook).

Only two places a platform component touches other namespaces, and both are controlled:

| Where | Why | Control (runbook phase) |
|---|---|---|
| Operators installed from OperatorHub get the proxy | Red Hat: OLM operators "inherit the cluster-wide proxy settings on their deployments" [R2], in whatever namespace they run; for the pods they manage, "Operators must handle setting environment variables for proxy settings" [R2] | **We control the catalog**, so only operators we approved can be installed at all, and they reach only allowlisted hosts. A Subscription can unset the proxy for an operator that does not need it: the variables "can also be unset using an empty value" [R2] (phase 7) |
| Any pod's image can come from `quay.io` | CRI-O pulls images for every pod through the node's proxy setting; it carries images only, never application traffic | `allowedRegistries` lists repositories, not whole registries: "Registries not in your allowlist are blocked" [R3] (phase 3). Kyverno's standard allowed-registries policy, with the list in a ConfigMap in the cluster, narrows application namespaces further at admission ([`image-policies/`](image-policies/)); it adds to `allowedRegistries`, it does not replace it |

The runbook's verification table proves it on a live cluster: a test pod in an application
namespace gets no proxy variables, cannot go out directly, and cannot pull an image from outside the
allowlist.

**References for this section** (`openshift/openshift-docs`, branch `enterprise-4.18`, read
2026-10-08):

- [R1] Cluster-wide proxy scope: [`networking/configuring_network_settings/enable-cluster-wide-proxy.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/networking/configuring_network_settings/enable-cluster-wide-proxy.adoc), "The system-wide proxy affects system components only, not user workloads." Same sentence in 4.22.
- [R2] OLM operators and the proxy: [`modules/olm-overriding-proxy-settings.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/olm-overriding-proxy-settings.adoc), "inherit the cluster-wide proxy settings on their deployments"; "Operators must handle setting environment variables for proxy settings in the pods for any managed Operands"; "can also be unset using an empty value".
- [R3] Image allowlist: [`modules/images-configuration-allowed.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/images-configuration-allowed.adoc), "Registries not in your allowlist are blocked."
- [R4] Proxy at install time: [`modules/installation-configure-proxy.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/installation-configure-proxy.adoc), "Production environments can deny direct access to the internet and instead have an HTTP or HTTPS proxy available."
- [R5] Release signatures: [`modules/update-process-workflow.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/update-process-workflow.adoc), "Red Hat publishes cryptographically-signed statements about published release images … by using image SHA digests as unique and immutable release image identifiers."
- [R6] Proxy object fields: [`modules/nw-proxy-configure-object.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/nw-proxy-configure-object.adoc).
- [R7] Hosts the cluster needs: [`installing/install_config/configuring-firewall.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/installing/install_config/configuring-firewall.adoc).

**No two-headed DNS.** The proxy resolves Red Hat's names; nodes resolve only internal names.
Internal DNS stays as it is.

**What we run:** an HA egress proxy with an allowlist, and the firewall rule that only the proxy may
go out. Nothing new inside the clusters.

**Risks and how they are handled:**

| Risk | Handling |
|---|---|
| Proxy outage stops image pulls | Run the proxy highly available, as a mirror registry would have to be |
| Red Hat changes hostnames | Track the firewall documentation; alert on proxy denies |
| An internal service missed from `noProxy` breaks a platform feature | Inventory before the proxy goes on; test in lower environments first |
| Telemetry sends cluster data to Red Hat | Leave it off unless security decides otherwise; updates don't need it |
| The proxy inspects TLS (decided: it re-signs with the enterprise CA) | The enterprise CA, already on every node, also goes into `trustedCA`; `sso.redhat.com` is not re-encrypted; signatures prove the content whatever the TLS path |

**Needs:** security's approval of the change, taken to it on the threat model with the condition that
applications cannot use the proxy by default; an answer on telemetry; a Red Hat
Support case for the open questions in the runbook. TLS inspection is decided: the proxy re-signs with
the enterprise CA, which every node trusts.

Detail: [`enterprise-proxy/README.md`](enterprise-proxy/README.md).

## Step 3: the mirror on a schedule, the fallback only

**What it is.** The mirror approach, automated: the Step 1 playbooks run on a schedule into the new
registries, so a person no longer runs the sync. It is the fallback only, if the change to the proxy
approach is not approved. Red Hat Quay on-prem would only change the registry product of this same
approach; it is not a third option. The rest of this section describes that Quay variant: a highly
available Red Hat Quay replaces the production mirror registries, one per datacenter. The clusters keep no
egress. The Step 1 playbooks fill Quay on a schedule from the mirroring bastion in each datacenter, the only machines that
reaches Red Hat through the proxy. The clusters pull everything from Quay.

**Can Quay sync from Red Hat by itself?** Not for OpenShift. Quay's repository mirroring copies
tags one repository at a time, organisation mirroring needs a Quay or Harbor source, and the proxy
cache fetches only what is pulled. None of them understands release payloads, catalogs, signatures
or the update graph, and repository mirroring drops the signatures 4.21 needs. **"Automatic" here
means a scheduled oc-mirror v2 job** (a systemd timer on each bastion running the Step 1
playbooks), which is what Red Hat documents.

**The OpenShift Update Service is required.** The clusters cannot reach Red Hat's update service,
so a local one serves the update graph from the graph image that each scheduled run puts in Quay.
One instance can serve every cluster. It must be restarted after each sync to load the new graph.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/three-steps/quay-sync.dark.png">
  <source srcset="diagrams/three-steps/quay-sync.light.png">
  <img alt="Step 3's scheduled sync. A systemd timer on the datacenter's mirroring bastion fires; flock skips the run if the last one is still going. The Step 1 playbooks download to disk with a persistent cache, then push the archive into Quay; a run that fails after its retries raises an alert, and the next run resumes from the cache. The Update Service is restarted to load the new graph image. A cluster admin applies the run's cluster resources in a change window, and the cluster then lists the new versions." src="diagrams/three-steps/quay-sync.light.png">
</picture>

*One run of the proposed Step 3 schedule, from a bastion's timer to the clusters.*

```text
BASTION (per datacenter)            QUAY                          CLUSTERS
1 timer fires                       4 org ocp4v2: release, .sig,    5 restart the OSUS (new graph)
2 flock: busy -> skip this run        catalogs, graph-image       6 admin applies cluster-resources
3 Step 1 playbooks; fail -> alert,                                7 oc adm upgrade lists new versions
  next run resumes (cache) --push-->
```

**Where Quay runs:** not on a cluster it serves. Either the Quay Operator on a separate infra or hub
cluster, with OpenShift Data Foundation or S3 storage, or standalone Quay on three or more RHEL hosts.

**What we run:** HA Quay with its database, Redis and object storage; Clair for image scanning; the
bastions and their timers; the Update Service.

**Needs:** a Quay subscription (OpenShift Platform Plus reportedly includes it); a platform for it;
the team's chosen build partner (Red Hat Consulting and a Quay specialist; no Red Hat document
requires Consulting); storage sized from the Step 1 dry-runs.

Detail: [`quay-onprem/README.md`](quay-onprem/README.md).

## The three steps side by side

| | Step 1: Ansible, current model | Step 2: the proxy approach | Step 3: mirror on a schedule (Quay variant) |
|---|---|---|---|
| Cluster egress | None | Red Hat hosts, through the proxy | None |
| Who copies content | A person runs the playbooks before each update | Nobody | A scheduled job |
| Update delayed by a failed sync | Yes | No sync to fail | The next scheduled run catches up |
| Local Update Service | Yes | No | Yes, required |
| Mirroring bastions | One per datacenter | Only to run the retrofit and fill the lab | One per datacenter, on a timer |
| Registries | Three new mirror registries (lab, DC1, DC2) | Lab registry; production registries until each cluster is retrofitted | HA Quay per datacenter; the lab keeps its mirror registry |
| Two-headed DNS | No | No | No |
| One-off node impact | None beyond today | One reboot (proxy), one drain (mirror removal) | Mirror config changes as today |
| Security approval | Mirror host to Red Hat (as today) | The change, on the threat model: applications cannot use the proxy by default | Mirror host to Red Hat |
| New things to run | Two bastions and three mirror registries on RHEL 9 | HA proxy with allowlist | HA Quay, storage, Clair, bastion timers, Update Service |
| Operator catalogs | Mirrored per version, list kept by hand | Red Hat's catalog, or a filtered one | Mirrored per version on a schedule |
| Ready to use | Now | After approval and one window per cluster | After a Quay build |

## Recommendation

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/three-steps/decision.dark.png">
  <source srcset="diagrams/three-steps/decision.light.png">
  <img alt="How the team chooses. The SMEs and the Product Owner shape the direction of this platform offering; this is the SME's recommendation from experience and modern best practice. The platform owner decides: the proxy approach, with no mirror, no sync and no local Update Service. The change goes to security on the threat model, with one condition: applications cannot use the proxy by default; the platform gives them no proxy settings (C2) and they have no route out (C1), proven by the runbook's tests 6 and 8. Approved leads to the preferred option, the proxy approach: VMware and TKG already update through this proxy; the retrofit runbook, lower environments first; the mirror is retired per cluster. Not approved leads to the fallback only, the mirror approach automated: the Ansible playbooks on a timer into the new registries, a local Update Service stays required; Red Hat Quay on-prem would only change the registry product, not a third option. Under either option the clusters must be on 4.20 before 4.18's EUS term ends on 25 February 2027. Ansible automates the upgrade in both cases, under the proxy option too: the hops, the update service, the registry settings and catalog gating; the difference is the manual mirror, which the proxy approach eliminates. With the proxy enabled on 4.18 first, the hops to 4.20 and 4.22 need no sync." src="diagrams/three-steps/decision.light.png">
</picture>

*Proposed decision flow. The platform owner's decision, the change with security, and the fallback. Only
the Ansible playbooks exist today.*

**The platform owner decides**, and the decision is the proxy approach. The change goes to security on
the threat model ([`enterprise-proxy/THREAT-MODEL.md`](enterprise-proxy/THREAT-MODEL.md)), with one
condition to meet: consumers and applications cannot use the proxy by default. The platform gives
application pods no proxy settings (C2) and they have no route out (C1); the runbook's tests 6 and 8
prove it on every cluster. With that condition met, we are good.

**Who shapes it.** The SMEs and the Product Owner shape the direction of this platform offering.
This is the SME's professional recommendation, from experience and modern best practice: the Ansible
mirror is a lot of work to maintain, and that time is better spent on the update process itself,
through the proxy. Ansible automates the upgrade under both options. With the proxy approach the
playbooks drive the retrofit and the updates themselves: the update runs, the checks and the evidence,
as the Step 1 playbooks do for mirroring today. With the mirror approach they also have to run and
maintain the mirror. The difference is the manual mirror, which the proxy approach eliminates.

**What Ansible automates under the proxy approach.** The work that stays in every option
([`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md), "What the proposal removes, and what stays") becomes
playbooks, as the mirroring is today:

- the updates themselves: each control-plane hop (`oc adm upgrade`), the waits and the health checks;
- the update service: clear `spec.upstream` and set the channel, so the cluster reads Red Hat's graph;
- the cluster registry configuration: the Red Hat pull secret, `allowedRegistries`, the proxy and its
  CA, and the mirror sets removed after the first connected update;
- catalog gating through GitOps: Git owns every CatalogSource and Subscription, the admission policies
  enforce the approved list;
- the retrofit itself, phase by phase, and the runbook's Verify tests as evidence.

The first four are written: [`enterprise-proxy-ansible/`](../enterprise-proxy-ansible/README.md) holds the
retrofit, update, remove-mirror and verify playbooks, tested offline against a stand-in cluster, waiting for
the lab cluster and the security decision. Red Hat's Knowledgebase solution "Converting a disconnected
cluster to a connected cluster" (Solution Verified, 2025) lists the catalog and pull secret steps they run.

**Order of work.** The cluster-wide proxy is a documented configuration on 4.18. Enabled first, it lets
the hops to 4.20 and 4.22 run straight from Red Hat with no sync at all, which is how the proxy approach
meets the 4.20 deadline without a mirror. Red Hat Support should confirm that removing the mirror sets
also removes the signature acknowledgment before 4.21 (runbook, phase 8).

**Why the proxy approach.** We are not looking for two-headed DNS, and no option needs it. We are
looking for a sustainable way to update our clusters that keeps pace with our growth. The disconnected
setup we run today was carried over from OpenShift 3.x, where it was the sound choice because the proxy
setup was a mess. OpenShift 4.x is far more advanced, and we have to be ready for the growth that follows it (OpenShift
5.x, for example): the
cluster-wide proxy is Red Hat's documented, supported way for enterprise customers to take updates and
fixes as they ship ("Production environments can deny direct access to the internet and instead have
an HTTP or HTTPS proxy available" [R4]), which is what operations and vulnerability management need.

The recommendation is two-fold. The two are independent options, not steps in sequence, and the
proxy approach needs no mirror at all:

1. **Preferred: the proxy approach** ([`enterprise-proxy/`](enterprise-proxy/README.md)). No
   mirror, no sync, no local Update Service: the clusters take their updates straight from Red Hat
   through the enterprise proxy, as a connected cluster does. Other teams already update their
   platforms through the same proxy, among them VMware and Tanzu Kubernetes Grid (TKG), so platform
   egress through the proxy to a vendor's hosts is established practice in our network. The proxy
   approach extends it to the OpenShift nodes, with only Red Hat's documented hosts allowed, using
   only documented configuration.
2. **Fallback only: the mirror approach, automated.** If security does not approve the change, the
   Ansible playbooks run on a schedule into the new registries, so a person no longer runs the sync;
   a local Update Service stays required. Red Hat Quay on-prem ([`quay-onprem/`](quay-onprem/README.md))
   would only change the registry product of this same approach; it is not a third option and adds
   no value of its own.

```text
Platform owner decides: the proxy approach
  -> the change goes to security on the threat model; one condition: applications cannot use the proxy by default
     approved     -> 1 · preferred: the proxy approach, the retrofit runbook; no mirror at all   (mirror retired per cluster)
     not approved -> 2 · fallback only: the mirror approach, automated on the new registries      (mirror stays, on a schedule)
Either option: the clusters must be on 4.20 before 4.18's EUS term ends on 25 Feb 2027.
Proxy first on 4.18, then the hops to 4.20 and 4.22 run with no sync; Ansible automates the hops either way.
```

In order:

1. **Now:** the platform owner takes the change to security on the threat model, with the precedent
   that VMware and TKG already update through the proxy, and the condition that applications cannot
   use the proxy by default.
2. **If security approves the change:** run the retrofit runbook in lower environments, then
   production, one cluster per window, on 4.18 and before the updates. The hops to 4.20 and 4.22 then
   run straight from Red Hat with no sync; the mirror is retired as each cluster is retrofitted.
3. **If security does not approve it:** build the two bastions and three registries
   ([`PREREQUISITES.md`](PREREQUISITES.md)) and put the Ansible playbooks on a schedule into them.
4. **Under either option:** the clusters must be on 4.20 before 4.18's EUS term ends on 25 February
   2027, so the decision has to come early enough to run the chosen approach by then. Ansible runs the
   hops in both cases.

## Decisions needed

| Decision | From | Blocks |
|---|---|---|
| The proxy approach: the platform owner's decision, taken to security on the threat model; condition: applications cannot use the proxy by default | Platform owner, with security | The proxy approach (preferred) or the mirror approach (fallback) |
| Telemetry and Insights on or off? | Security | The proxy allowlist and the pull secret |
| ~~Will the proxy intercept TLS to Red Hat hosts?~~ Answered 2026-10-09: yes, with the enterprise CA every node trusts | Network team | The proxy configuration |
| Filtered or stock operator catalog? | Platform team | The catalog phase of the proxy approach; the catalog runs of the mirror approach |
| Quay subscription, platform and build partner | Management | Only if the fallback is chosen and Quay is picked as its registry product |
| Five RHEL 9 hosts, DNS names, internal-CA certificates and firewall flows | Infrastructure, network teams | Everything ([`PREREQUISITES.md`](PREREQUISITES.md)) |
| Which datacenter holds the lab; how many clusters each production registry serves | Platform team | Registry layout, fallback only |
| Monthly z-stream window | Platform team | Either option |

## Diagram sources

The figures are drawn in [`diagrams/three-steps/source.html`](diagrams/three-steps/source.html) and
[`../oc-mirror-ansible/docs/diagrams/mirroring/source.html`](../oc-mirror-ansible/docs/diagrams/mirroring/source.html),
and rendered to the PNGs beside them with [diagram-kit](https://github.com/ephico2real2/diagram-kit):

```sh
# once: see PROBLEM-STATEMENT.md, Diagram sources, for installing diagram-kit into .venv
.venv/bin/diagram-render docs/diagrams/three-steps/source.html docs/diagrams/three-steps \
  three-steps,decision,retrofit,quay-sync
.venv/bin/diagram-render oc-mirror-ansible/docs/diagrams/mirroring/source.html oc-mirror-ansible/docs/diagrams/mirroring \
  run-flow,network-routes,upgrade-path-runs
```

A figure, its text twin and its page change together. The Word copy embeds the light PNGs.
