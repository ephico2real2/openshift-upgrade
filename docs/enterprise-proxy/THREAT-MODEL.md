# Threat model: updating a cluster through our enterprise proxy

The Step 2 design ([`README.md`](README.md)) as a threat model, platform side. It covers the update
described in [`../openshift-update-egress.html`](../openshift-update-egress.html) (*Option 1 in detail*), drawn
as trust boundaries and data flows. Every control is taken from Red Hat's OpenShift documentation.
It shows three things:

1. **The platform starts every update.** The Cluster Version Operator, CRI-O on the nodes and OLM
   make the requests; the cluster admin only picks the target.
2. **Every flow is HTTPS on TCP 443 through our enterprise proxy, to named Red Hat hosts.** The proxy
   allows only those hosts, and the firewall lets only the proxy out.
3. **Application pods cannot use the cluster proxy to reach the internet.** The platform gives them no
   proxy settings, and the firewall stops them.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/threat-model/proxy-update-threat-model.dark.png">
  <source srcset="diagrams/threat-model/proxy-update-threat-model.light.png">
  <img alt="Threat model of updating a cluster through our enterprise proxy, platform side. Inside the OpenShift cluster, the platform (the nodes and the openshift namespaces) starts every update. The Cluster Version Operator fetches the update graph from api.openshift.com and the release signature from mirror.openshift.com, and checks it with Red Hat's keys. CRI-O on each node pulls the release images from quay.io and checks their sigstore signatures. OLM pulls operator images from registry.redhat.io, from approved catalogs only. Every one of these flows is HTTPS on TCP 443 through the enterprise proxy, which allows only these Red Hat hosts, answers anything else with 403, and inspects TLS with the enterprise CA that the platform trusts through the proxy's trustedCA bundle. The firewall lets only the proxy out. Application pods get no proxy settings from the platform and have no route out, so they are stopped at the firewall. The cluster admin only picks the target with oc adm upgrade. Each control is taken from Red Hat's OpenShift documentation." src="diagrams/threat-model/proxy-update-threat-model.light.png">
</picture>

*Trust boundaries (red dashed): the internet, our enterprise network with the proxy and the firewall,
and the OpenShift cluster, where the platform starts every update and application namespaces have no
way out. C1–C7 are the controls.*

## Who calls which Red Hat host

| Caller (platform) | Red Hat host, TCP 443 through the proxy | Why |
|---|---|---|
| Cluster Version Operator (`openshift-cluster-version`) | `api.openshift.com` | Update graph: versions, digests, known risks |
| Cluster Version Operator | `mirror.openshift.com` | Release signature, looked up by digest |
| CRI-O on each node | `quay.io` and its CDN hosts | Release images and their sigstore signatures |
| OLM | `registry.redhat.io` | Operator images from the catalogs we approve |
| Cluster admin (`oc adm upgrade --to=…`) | none | Picks the target; the CVO does the rest |

## Controls

| # | Control | Red Hat documentation | Runbook phase | Verify |
|---|---|---|---|---|
| C1 | The firewall lets only the proxy out; nodes and pods have no direct route | Hosts from "Configuring your firewall" ([`configuring-firewall.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/installing/install_config/configuring-firewall.adoc)) | 0 | Tests 4 and 8 |
| C2 | The cluster-wide proxy is set for platform components only | "The system-wide proxy affects system components only, not user workloads." ([`enable-cluster-wide-proxy.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/networking/configuring_network_settings/enable-cluster-wide-proxy.adoc)) | 4 | Tests 1 and 6 |
| C3 | The proxy allows only the documented Red Hat hosts; anything else gets 403 | [`configuring-firewall.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/installing/install_config/configuring-firewall.adoc) | 0 | Tests 5 and 11 |
| C4 | Release and image signatures are checked | The CVO validates Red Hat's "cryptographically-signed statements" about release images by digest ([`update-process-workflow.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/update-process-workflow.adoc)); CRI-O checks sigstore signatures from 4.21 | Built in | Test 2 |
| C5 | Nodes pull only from allowed repositories | "Registries not in your allowlist are blocked" ([`images-configuration-allowed.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/images-configuration-allowed.adoc)) | 3 | Test 9 |
| C6 | Only operators from catalogs we approve, since operators "inherit the cluster-wide proxy settings" | [`olm-overriding-proxy-settings.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/olm-overriding-proxy-settings.adoc) | 7 | Catalog policy suites ([`../catalog-policies/`](../catalog-policies/)) |
| C7 | The enterprise CA the proxy re-signs with is in `user-ca-bundle` (`trustedCA`) | The bundle "is merged with the RHCOS trust bundle and injected into the trust store of platform components that make egress HTTPS calls" ([`proxy-certificates.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/security/certificate_types_descriptions/proxy-certificates.adoc)); a re-encrypting proxy excludes `sso.redhat.com` ([`cluster-wide-proxy-preqs.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/cluster-wide-proxy-preqs.adoc)) | 0, 4a | Tests 1 to 3 |

Tests are the runbook's *Verify* table.

## What the design stops

| # | Attempt | Stopped by |
|---|---|---|
| T1 | An application pod reaches the internet | C2 (no proxy settings), C1 (no route out) |
| T2 | A node or platform component reaches a host that is not Red Hat's | C3, C1 |
| T3 | A release or image that Red Hat did not sign is installed | C4 |
| T4 | A node pulls an image from a repository we did not allow | C5 |
| T5 | An operator we did not approve is installed | C6 |

## Diagram source

[`diagrams/threat-model/source.html`](diagrams/threat-model/source.html), rendered with
[diagram-kit](https://github.com/ephico2real2/diagram-kit) (installation in `docs/PROBLEM-STATEMENT.md`,
Diagram sources):

```bash
.venv/bin/diagram-render docs/enterprise-proxy/diagrams/threat-model/source.html \
  docs/enterprise-proxy/diagrams/threat-model proxy-update-threat-model
```
