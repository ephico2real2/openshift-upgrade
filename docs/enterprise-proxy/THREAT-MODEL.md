# Threat model: updating a cluster through our enterprise proxy

The proxy approach ([`README.md`](README.md), the retrofit runbook) as a threat model, platform side. It covers the update
described in [`../openshift-update-egress.html`](../openshift-update-egress.html) (*Option 1 in detail*), drawn
as trust boundaries and data flows. Controls C1 to C7 are taken from Red Hat's OpenShift documentation,
quoted and linked below; C8 is our own admission policy and is marked as such. The platform owner
decides on the proxy approach and takes the change to security on this document; the condition that
matters is point 3, that applications cannot use the proxy by default. It shows four things:

1. **The platform starts every update.** The Cluster Version Operator, CRI-O on the nodes and OLM
   make the requests; the cluster admin only picks the target.
2. **Every flow is HTTPS on TCP 443 through our enterprise proxy, to named Red Hat hosts.** The proxy
   allows only those hosts, and the firewall lets only the proxy out.
3. **Application pods cannot use the cluster proxy to reach the internet.** The platform gives them no
   proxy settings, and the firewall stops them. An application team that sets a proxy in its own
   deployment does so deliberately, under our existing policy; that is not something the platform does.
4. **Only allowed registries.** Pods may use images only from the allowed registries, Red Hat's and
   our internal ones: the nodes enforce `allowedRegistries` on every pull, and an admission policy
   (Kyverno, or another policy engine) refuses any other registry before a pod is created.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/threat-model/proxy-update-threat-model.dark.png">
  <source srcset="diagrams/threat-model/proxy-update-threat-model.light.png">
  <img alt="Threat model of updating a cluster through our enterprise proxy, platform side. Inside the OpenShift cluster, the platform (the nodes and the openshift namespaces) starts every update. The Cluster Version Operator fetches the update graph from api.openshift.com and the release signature from mirror.openshift.com, and checks the signature with Red Hat's keys. CRI-O on each node pulls the release images from quay.io and, from OpenShift 4.21, checks their sigstore signatures. OLM installs operators from approved catalogs only; CRI-O pulls their images from registry.redhat.io. Every one of these flows is HTTPS on TCP 443 through the enterprise proxy, which allows only these Red Hat hosts, answers anything else with 403, and inspects TLS with the enterprise CA that the platform trusts through the proxy's trustedCA bundle. The firewall lets only the proxy out. Application pods get no proxy settings from the platform and have no route out, so they are stopped at the firewall. An admission policy (Kyverno) lets pods use images only from the allowed registries, Red Hat's and our internal ones, on top of the nodes' allowedRegistries. The cluster admin only picks the target with oc adm upgrade. Each control is taken from Red Hat's OpenShift documentation, except the admission policy, which is ours." src="diagrams/threat-model/proxy-update-threat-model.light.png">
</picture>

*Trust boundaries (red dashed): the internet, our enterprise network with the proxy and the firewall,
and the OpenShift cluster, where the platform starts every update and application namespaces have no
way out. C1–C8 are the controls.*

The same update, step by step: who calls which Red Hat host, and the controls on each step.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/threat-model/proxy-update-steps.dark.png">
  <source srcset="diagrams/threat-model/proxy-update-steps.light.png">
  <img alt="The same update step by step. Each step names the platform component that makes the request, the Red Hat host it reaches over TCP 443 through the enterprise proxy, and the controls that apply. Step 1: the Cluster Version Operator asks api.openshift.com for the update graph. Step 2: the cluster admin picks the target with oc adm upgrade; no egress. Step 3: the CVO fetches the release signature from mirror.openshift.com and checks it with Red Hat's keys. Step 4: CRI-O on each node pulls the release images from quay.io and its CDN, only from allowed repositories. Step 5, from OpenShift 4.21 only: CRI-O checks each image's sigstore signature; on 4.18 to 4.20 this step is not active and the CVO's release signature check in step 3 is the signature control. Step 6: OLM installs operators from approved catalogs only; CRI-O pulls their images from registry.redhat.io. Step 7: application pods are admitted only with images from the allowed registries and have no proxy settings and no route out. Every request crosses the enterprise proxy, which allows only Red Hat hosts and re-signs TLS with the enterprise CA the platform trusts." src="diagrams/threat-model/proxy-update-steps.light.png">
</picture>

*Steps ① to ⑥ are the platform's; ⑦ shows that application pods are admitted only with allowed images
and have no way out. Step ⑤ exists from OpenShift 4.21 only: while the clusters are on 4.18 to 4.20
it is not active, and the CVO's release signature check in step ③ is the signature control.*

## Who calls which Red Hat host

| Caller (platform) | Red Hat host, TCP 443 through the proxy | Why |
|---|---|---|
| Cluster Version Operator (`openshift-cluster-version`) | `api.openshift.com` | Update graph: versions, digests, known risks |
| Cluster Version Operator | `mirror.openshift.com` | Release signature, looked up by digest. The CVO also tries the other documented source, `storage.googleapis.com/openshift-release`; the proxy denies it, and Red Hat says the CVO "needs only a single functioning source" ([`configuring-firewall.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/configuring-firewall.adoc)). Expect that deny in the proxy logs (test 11) |
| CRI-O on each node | `quay.io` and its CDN hosts | Release images; from OpenShift 4.21 only, their sigstore signatures too (not active on 4.18 to 4.20) |
| CRI-O on each node, for the catalog and operator pods OLM creates | `registry.redhat.io` (layers from the Quay CDN) | Operator images from the catalogs we approve |
| Cluster admin (`oc adm upgrade --to=…`) | none | Picks the target; the CVO does the rest |

## Controls

| # | Control | Red Hat documentation | Runbook phase | Verify |
|---|---|---|---|---|
| C1 | The firewall lets only the proxy out; nodes and pods have no direct route | Hosts from "Configuring your firewall" ([`configuring-firewall.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/installing/install_config/configuring-firewall.adoc)) | 0 | Tests 4 and 8 |
| C2 | The cluster-wide proxy is set for platform components only | "The system-wide proxy affects system components only, not user workloads." ([`enable-cluster-wide-proxy.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/networking/configuring_network_settings/enable-cluster-wide-proxy.adoc)) | 4 | Tests 1 and 6 |
| C3 | The proxy allows only the documented Red Hat hosts; anything else gets 403 | [`configuring-firewall.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/installing/install_config/configuring-firewall.adoc) | 0 | Tests 5 and 11 |
| C4 | Release and image signatures are checked | The CVO validates Red Hat's "cryptographically-signed statements" about release images by digest, with "a list of built-in public keys" ([`update-process-workflow.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/update-process-workflow.adoc)); CRI-O checks sigstore signatures from 4.21 (runbook phase 8) | Built in; exercised in phase 8 | After phase 8: `oc get clusterversion version -o jsonpath='{.status.history[0].verified}'` is `true` ("verified indicates whether the provided update was properly verified before it was installed", [`clusterversion-config-openshift-io-v1.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/rest_api/config_apis/clusterversion-config-openshift-io-v1.adoc)) |
| C5 | Nodes pull only from allowed repositories | "Registries not in your allowlist are blocked" ([`images-configuration-allowed.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/images-configuration-allowed.adoc)) | 3 | Test 9 |
| C6 | Only the catalogs we approve are on; operators installed from them reach only the same Red Hat hosts, because they "inherit the cluster-wide proxy settings on their deployments" | `disableAllDefaultSources` "is an override that controls availability of all default catalogs" ([`olm-operatorhub-architecture.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/olm-operatorhub-architecture.adoc)); proxy inheritance from [`olm-overriding-proxy-settings.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/olm-overriding-proxy-settings.adoc) | 7 | `oc get catalogsource -n openshift-marketplace` lists only approved sources; catalog policy suites ([`../catalog-policies/`](../catalog-policies/)) |
| C7 | The enterprise CA the proxy re-signs with is in `user-ca-bundle` (`trustedCA`) | The bundle "is merged with the RHCOS trust bundle and injected into the trust store of platform components that make egress HTTPS calls" ([`proxy-certificates.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/security/certificate_types_descriptions/proxy-certificates.adoc)); a re-encrypting proxy excludes `sso.redhat.com` ([`cluster-wide-proxy-preqs.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/cluster-wide-proxy-preqs.adoc)) | 0, 4a | Tests 1 to 3 |
| C8 | Pods may use images only from the allowed registries, Red Hat's and our internal ones (the enterprise registry, whether Artifactory, a GitLab container registry, Harbor or Quay, and the oc-mirror registry until phase 9); anything else is refused at admission | Our admission policy: Kyverno's standard allowed-registries policy with the list in a ConfigMap ([`../image-policies/`](../image-policies/)); `allowedRegistries` (C5) stays on the nodes for every pull | 3, then the policy rollout in `image-policies/` | Test 9, and `oc run` with an image from another registry is refused at admission |

Tests are the runbook's *Verify* table.

## What the design stops

| # | Attempt | Stopped by |
|---|---|---|
| T1 | An application pod reaches the internet | C2 (no proxy settings), C1 (no route out) |
| T2 | A node or platform component reaches a host that is not Red Hat's | C3, C1 |
| T3 | A release or image that Red Hat did not sign is installed | C4 |
| T4 | A node pulls an image from a repository we did not allow | C5 |
| T5 | An operator we did not approve is installed | C6 |
| T6 | A pod is created with an image from a registry that is not Red Hat's or ours | C8, then C5 on the pull |

## Diagram source

[`diagrams/threat-model/source.html`](diagrams/threat-model/source.html), rendered with
[diagram-kit](https://github.com/ephico2real2/diagram-kit) (installation in `docs/PROBLEM-STATEMENT.md`,
Diagram sources):

```bash
.venv/bin/diagram-render docs/enterprise-proxy/diagrams/threat-model/source.html \
  docs/enterprise-proxy/diagrams/threat-model proxy-update-threat-model,proxy-update-steps
```
