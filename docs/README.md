# OpenShift update egress: docs

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/three-steps/three-steps.dark.png">
  <source srcset="diagrams/three-steps/three-steps.light.png">
  <img alt="Three steps keep the clusters current. Step 1, built: a person runs the Ansible oc-mirror v2 playbooks on the mirroring bastion of each datacenter before each update, into the lab and production mirror registries, and the cluster stays disconnected with a local Update Service. Step 2, the platform owner's decision: every node reaches Red Hat's hosts through the enterprise proxy, with no mirror, no sync and no local Update Service, and Ansible runs the retrofit and the updates. Step 3, the fallback only: the same playbooks run on a schedule into the new registries and the cluster keeps no egress with a local Update Service; Red Hat Quay on-prem would only change the registry product. All three open the same Red Hat hosts and none needs two-headed DNS." src="diagrams/three-steps/three-steps.light.png">
</picture>

*The three steps; [`SOLUTIONS.md`](SOLUTIONS.md) presents them, [`PREREQUISITES.md`](PREREQUISITES.md) lists the hosts they need.*

| Path | What it is |
|---|---|
| [`PREREQUISITES.md`](PREREQUISITES.md) | The hosts every step needs: a mirroring bastion per datacenter, the lab and two production mirror registries on RHEL 9, sizing, flows, and moving clusters off the old registry |
| [`SOLUTIONS.md`](SOLUTIONS.md) | The three steps side by side: Ansible for today's process, the proxy approach (the platform owner's decision), the mirror on a schedule as the fallback; with the recommendation and the decisions needed |
| [`enterprise-proxy/`](enterprise-proxy/README.md) | Step 2, the proxy approach: the conversion of a disconnected cluster explained phase by phase, for review and teaching; the playbooks below run it |
| [`../enterprise-proxy-ansible/`](../enterprise-proxy-ansible/README.md) | How we do Step 2, the Ansible playbooks (with the figures of one cluster end to end and of one update hop): retrofit (phases 1 to 7, one tag each), update (phase 8 and later hops, with the signature check), remove the mirror (phase 9), verify (the evidence file); tested offline against a stand-in cluster |
| [`enterprise-proxy/THREAT-MODEL.md`](enterprise-proxy/THREAT-MODEL.md) | Threat model of an update through the proxy: the platform starts every flow, each flow is TCP 443 through the proxy to a named Red Hat host, application pods cannot reach the internet |
| [`quay-onprem/`](quay-onprem/README.md) | Step 3's Quay variant: Red Hat Quay on-prem, filled on a schedule by oc-mirror v2, with the OpenShift Update Service; the fallback only |
| [`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md) | Why the current offline image sync cannot keep pace, measured, and the two designs that replace it |
| [`DESIGN-DECISIONS.md`](DESIGN-DECISIONS.md) | The options, the five open decisions with their recommendations, and what is still unanswered |
| [`openshift-update-egress.html`](openshift-update-egress.html) | The full plan: research findings, line-by-line check of the original plan, host allowlist, security controls, rollout, sources. It is a page fragment (starts at `<title>`); a browser opens it directly |
| [`diagrams/`](diagrams/) | The plan page's four figures as light and dark PNGs |
| [`diagrams/disconnected-update-problem/`](diagrams/disconnected-update-problem/) | Source page and PNGs for the first three figures in the problem statement |
| [`diagrams/prerequisites/`](diagrams/prerequisites/) | Source page and PNGs for the target layout of bastions and registries |
| [`diagrams/three-steps/`](diagrams/three-steps/) | Source page and PNGs for the three steps, the decision flow, the retrofit flow and the fallback's scheduled sync |
| [`catalog-policies/`](catalog-policies/) | Admission policies that limit operator catalogs, and the scripts that test them |
| [`image-policies/`](image-policies/) | Kyverno's standard allowed-registries policy for application pods (list in a ConfigMap in the cluster), on top of `allowedRegistries`; why both are needed; offline tests |
| [`upstream/`](upstream/) | Draft issues for upstream projects we rely on (mirror-gui), not yet posted |
| [`decks/`](decks/) | The two slide decks (the update plan and the threat model) as their published source files, with the map from each embedded figure to its PNG here |
| [`hetzner-server/merge-home-into-root.md`](hetzner-server/merge-home-into-root.md) | How to merge `/home` into `/` on a Hetzner server with RAID 1, on the running system |
| `SOLUTIONS.docx`, `PREREQUISITES.docx`, `PROBLEM-STATEMENT.docx`, `DESIGN-DECISIONS.docx` | Word copies of the four Markdown documents, with the light figures embedded. Generated; edit the Markdown and rebuild |
| [`tools/md2docx.js`](tools/md2docx.js) | Builds the Word copies: `npm install docx`, then `node tools/md2docx.js PROBLEM-STATEMENT.md PROBLEM-STATEMENT.docx` |

## catalog-policies

| File | Purpose |
|---|---|
| `vap-olm-catalogs.yaml` | ValidatingAdmissionPolicies for a filtered catalog (model A) |
| `vap-olm-package-allowlist.yaml` | ValidatingAdmissionPolicies for an allowlist on the stock catalog (model B) |
| `kyverno-olm-catalogs.yaml`, `gatekeeper-olm-catalogs.yaml` | The CatalogSource rule for Kyverno and Gatekeeper |
| `test-vap.sh`, `run-vap-final.sh`, `matrix.sh` | Model A suite, and runners that create a kind cluster for it |
| `test-scenario-b.sh`, `run-scenario-b.sh` | Model B suite and its runner |
| `test-cs.sh`, `engines.sh` | CatalogSource-only suite for the in-cluster Kyverno and Gatekeeper run |
| `offline/` | Fixtures and a `gator` suite for testing the Kyverno and Gatekeeper policies without a cluster |

The runners use kind with podman (`KIND_EXPERIMENTAL_PROVIDER=podman`) and need inputs that are not
in this folder:

| Missing input | Where it came from |
|---|---|
| `olm-crds.yaml` | `https://raw.githubusercontent.com/operator-framework/operator-lifecycle-manager/master/deploy/upstream/quickstart/crds.yaml` |
| `clustercatalog-crd.yaml` | The CustomResourceDefinition documents from `https://raw.githubusercontent.com/openshift/operator-framework-operator-controller/main/openshift/catalogd/manifests.yaml` |
| `bin/kyverno`, `bin/gator` | Release assets `kyverno-cli_v1.19.1_darwin_arm64.tar.gz` (kyverno/kyverno) and `gator-v3.23.1-darwin-arm64.tar.gz` (open-policy-agent/gatekeeper) |

Both CRD URLs track a moving branch, so a fresh download may differ from what the suites ran against
on 2026-09-25.

## Provenance

These files were first written on 2026-09-25 in a temporary directory that was later cleared. They
were rebuilt on 2026-10-04 from that session's transcript by replaying every write, edit and
file-changing shell command in its original order.

- `vap-olm-catalogs.yaml` and `run-vap-final.sh` were compared with copies the original session
  printed after its last change, and match. The other policy and test files were checked against
  line counts and command output from that session.
- `openshift-update-egress.html` has no such reference copy. Every recorded patch applied exactly
  once in order, and the page renders without errors.
- The PNGs in `diagrams/` were rendered again from the restored page, not recovered.
- The page published on 2026-09-25 is no longer reachable at its old link.
