# Threat model: updating a cluster through the enterprise proxy

The Step 2 design ([`README.md`](README.md)) as a threat model. It covers the Option 1 update from
[`../openshift-update-egress.html`](../openshift-update-egress.html) (*Option 1 in detail*), drawn as
trust boundaries and data flows, with the control on every flow. It shows three things:

1. **The platform starts every update.** The Cluster Version Operator, CRI-O on the nodes and OLM
   make the requests; an admin picks the target. Nothing in an application namespace takes part.
2. **Every flow is HTTPS on TCP 443 through the proxy, to named Red Hat hosts.** The proxy allows only
   those hosts and the firewall lets only the proxy out.
3. **Application pods cannot use the cluster proxy to reach the internet.** The platform never gives
   them the proxy settings, and they have no direct route.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/threat-model/proxy-update-threat-model.dark.png">
  <source srcset="diagrams/threat-model/proxy-update-threat-model.light.png">
  <img alt="Threat model of updating a cluster through the enterprise proxy. Inside the OpenShift cluster, the platform (the nodes and the openshift namespaces) starts every update: the Cluster Version Operator fetches the update graph and the release signature, CRI-O on each node pulls the payload images and their sigstore signatures, and OLM pulls only approved operators. Every one of these flows is HTTPS on TCP 443 through the enterprise proxy, whose allowlist holds only Red Hat hosts: api.openshift.com, mirror.openshift.com, quay.io with its CDN, and registry.redhat.io; anything else gets 403. The cluster admin only picks the target with oc adm upgrade. Application namespaces sit in their own trust boundary: the platform gives application pods no proxy settings and the firewall gives them no direct route, so an attempt to reach any other internet host is blocked (threat T1). A pod's image is still pulled by CRI-O through the proxy, so the image allowlist decides what may be pulled (threat T4, control C5). Residual risk and open items: a team may set its own proxy in its pods, which is deliberate and still reaches only Red Hat hosts; OLM operators inherit the proxy, so only approved catalogs; the proxy inspects TLS and re-signs with the enterprise CA, which the nodes and platform components trust through the proxy's trustedCA bundle, so it sees registry tokens while the release and image signatures still prove the content." src="diagrams/threat-model/proxy-update-threat-model.light.png">
</picture>

*Trust boundaries (red dashed): the internet, the cluster, and inside it the platform, which starts every
update, and the application namespaces. Platform flows (solid) are TCP 443 through the proxy to Red Hat
hosts; C1–C7 are the controls, T1, T4 and T6 the threats drawn where they occur (all seven are in the
table below).*

## Who calls which Red Hat host

| Step | Caller (platform) | Red Hat host, TCP 443 through the proxy | Why |
|---|---|---|---|
| ① | Cluster Version Operator (`openshift-cluster-version`) | `api.openshift.com` | Update graph: versions, digests, known risks |
| ② | An admin (`oc adm upgrade --to=…`) | none | Picks the target; no egress |
| ③ | Cluster Version Operator | `mirror.openshift.com` | Release signature, looked up by digest |
| ④ | CRI-O on each node | `quay.io`, `cdn01–06.quay.io` | Release payload images; layers come from the CDN |
| ⑤ | CRI-O on each node | `quay.io` (`sha256-<digest>.sig`) | Sigstore signature of each image (from 4.21) |
| ⑥ | OLM | `registry.redhat.io` | Catalog, bundle and operator images we approved |

The full allowlist, including the hosts still being confirmed with Red Hat (`console.redhat.com`,
`sso.redhat.com`) and the telemetry hosts that depend on decision D3, is in the runbook, phase 0.

## Threats and controls

| # | Threat | Control | Where it is put in place | Proof (runbook, Verify) |
|---|---|---|---|---|
| T1 | An application pod reaches the internet, directly or through the cluster proxy | **C1** the firewall lets only the proxy out · **C2** the platform gives pods no proxy settings · **C3** the proxy allows Red Hat hosts only | Phase 0 (firewall, allowlist), phase 4 (`proxy/cluster`) | Test 6 (pod gets no proxy), test 8 (pod cannot go direct), test 7 if phase 5 is used |
| T2 | A node or platform component reaches a host that is not Red Hat's | **C3** allowlist, else 403 · **C1** no direct route | Phase 0 | Test 5 (allowlist holds), test 4 (node has no direct route), test 11 (proxy logs: node IPs only, allowlisted hosts only) |
| T3 | A tampered release or image, in transit or at the source | **C4** the CVO checks Red Hat's GPG signature of the release; CRI-O checks the sigstore signature of each image (`ClusterImagePolicy` `openshift`, from 4.21); TLS on every flow | Built in | Test 2 (update checks work); a bad signature stops the update |
| T4 | A workload pulls an arbitrary public image from `quay.io` through the nodes' proxy | **C5** `allowedRegistries` by repository on the nodes; the Kyverno policy narrows application namespaces further | Phase 3; [`../image-policies/`](../image-policies/) | Test 9 (pulls outside the allowlist fail) |
| T5 | An unapproved operator is installed and inherits the proxy | **C6** only catalogs and packages we approve, enforced by admission policies | Phase 7; [`../catalog-policies/`](../catalog-policies/) | The catalog policy test suites |
| T6 | The proxy inspects TLS: it decrypts the platform's traffic, including registry tokens, and could alter content | **C7** the enterprise CA (already on every node) is in `user-ca-bundle` / `trustedCA`, so platform components validate the proxy's certificates · **C4** signatures prove the content whatever the TLS path · `sso.redhat.com` not re-encrypted · the proxy is part of the trusted base: protect its logs and admin access | Phase 0 (D4, answered), phase 4a | Test 1 (proxy applied with `trustedCA`), test 2 and test 3 (TLS validates through the proxy) |
| T7 | A proxy outage stops updates and image pulls | Run the proxy highly available | Phase 0 | Proxy monitoring; the mirror stays until phase 9 |

**Not a gap: an application team that sets a proxy in its own deployment.** That is a deliberate
choice teams are already allowed to make; the platform never makes it for them (C2). Even then the
proxy allows only Red Hat's hosts (C3), so it is not a way to the internet. With a separate proxy
listener for the clusters' nodes (phase 0), such a pod cannot use the platform's listener at all.

## References

- **C2:** Red Hat: "The system-wide proxy affects system components only, not user workloads."
  [`networking/configuring_network_settings/enable-cluster-wide-proxy.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/networking/configuring_network_settings/enable-cluster-wide-proxy.adoc)
  (4.18; same in 4.22).
- **C3, hosts:** [`installing/install_config/configuring-firewall.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/installing/install_config/configuring-firewall.adoc).
- **C4:** Red Hat publishes "cryptographically-signed statements about published release images …
  by using image SHA digests":
  [`modules/update-process-workflow.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/update-process-workflow.adoc).
- **C5:** "Registries not in your allowlist are blocked":
  [`modules/images-configuration-allowed.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/images-configuration-allowed.adoc).
- **C7:** the `trustedCA` bundle "is merged with the RHCOS trust bundle and injected into the trust
  store of platform components that make egress HTTPS calls":
  [`security/certificate_types_descriptions/proxy-certificates.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/security/certificate_types_descriptions/proxy-certificates.adoc).
  A proxy that re-encrypts must exclude `sso.redhat.com`:
  [`modules/cluster-wide-proxy-preqs.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/cluster-wide-proxy-preqs.adoc).
- **C6, OLM and the proxy:** operators "inherit the cluster-wide proxy settings on their deployments":
  [`modules/olm-overriding-proxy-settings.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/olm-overriding-proxy-settings.adoc).

## Diagram source

[`diagrams/threat-model/source.html`](diagrams/threat-model/source.html), rendered with
[diagram-kit](https://github.com/ephico2real2/diagram-kit) (installation in `docs/PROBLEM-STATEMENT.md`,
Diagram sources):

```bash
.venv/bin/diagram-render docs/enterprise-proxy/diagrams/threat-model/source.html \
  docs/enterprise-proxy/diagrams/threat-model proxy-update-threat-model
```
