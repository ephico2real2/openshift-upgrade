# Image policies: which images application pods may use

Opening `quay.io` through the proxy opens anyone's public images there. Two controls limit what runs,
and we use both:

| | `allowedRegistries` (runbook phase 3) | Kyverno policy (this folder) |
|---|---|---|
| Where it is enforced | CRI-O on every node, at every image pull | API server admission, when a pod or controller is created or changed |
| What it covers | Every pull: platform and application pods, static pods, builds ("for builds and pods" [R8]), `crictl pull` on a node | Pods and their controllers in application namespaces; platform namespaces are excluded |
| How strict it can be | Must include everything the **platform** pulls, including `quay.io/openshift-release-dev`; "all registries … are blocked unless explicitly listed" [R9] | Can be stricter for applications: they never need the release repository |
| Scope | One list for the whole cluster | Per namespace, with Kyverno `PolicyException`s for a named team |
| Rollout | Any running pod that pulls from an unlisted registry fails on its next pull | Audit first: PolicyReports show who would be blocked, then switch to Deny |
| What a team sees | `ErrImagePull` ("not allowed") after the deploy | An error at `oc apply`, naming the image and the approved repositories |
| Node effect | Changes to `policy.json` need no drain; CRI-O reloads | None |
| If it is down | Not applicable: part of the node | Depends on `failurePolicy`; run Kyverno highly available |
| Support | Red Hat, part of OpenShift | Kyverno is a CNCF project, not shipped or supported by Red Hat |

**Why Kyverno cannot replace `allowedRegistries`:** admission sees API objects, not pulls. A build's
`FROM` image is pulled inside the build pod, a static pod never goes through admission, and an admin
can pull on a node directly. CRI-O checks all of these; Kyverno sees none of them. Kyverno is also
one more service that has to be up for admission to work. So `allowedRegistries` stays the
cluster-wide backstop, and Kyverno adds the stricter, friendlier rule for applications.

## The policy

[`kyverno-workload-image-repos.yaml`](kyverno-workload-image-repos.yaml) is a Kyverno
`ValidatingPolicy` (CEL). Kyverno 1.19 deprecates the older `kyverno.io/v1` `ClusterPolicy`.

- **Matches:** Pods (including ephemeral containers), Deployments, StatefulSets, DaemonSets,
  ReplicaSets, Jobs and CronJobs, on create and update.
- **Skips:** `openshift`, `openshift-*`, `kube-*`, `default` and `kyverno`. Users cannot create
  namespaces with the `openshift-` or `kube-` prefixes.
- **Allows:** images whose reference starts with `registry.redhat.io/`, `registry.access.redhat.com/`,
  `registry.connect.redhat.com/`, the in-cluster registry, or the datacenter mirror registry. The
  trailing `/` means `registry.redhat.io.evil.example.com/…` does not match, and a short name such as
  `nginx` (Docker Hub) is denied.
- **Before using it:** replace `registry-dc1.example.com:8443/` with each cluster's mirror registry and
  add the registries from the phase 1 inventory that applications pull from.

## Test

```bash
KYVERNO=/path/to/kyverno ./test.sh     # kyverno CLI v1.19.1, offline
```

The fixtures in [`tests/`](tests/) are named after the expected result. Recorded on 2026-10-08:
12 of 12 as expected. Breaking the allowlist on purpose made the script report four failures, so a
regression is caught. The script checks each case on its own because `kyverno test` reported an
invalid policy as passing.

Limits:

- Offline only. A kind cluster could not run pods in the session's container, so the policy has
  not run against an API server, and not on OpenShift.
- `ReplicaSet` is matched as well as `Deployment`. A Deployment the policy denies never creates a
  ReplicaSet; one admitted before the policy existed keeps its ReplicaSet until it changes.

## Rolling it out

1. **Mirror Kyverno's images.** They come from `reg.kyverno.io/kyverno/`, which `allowedRegistries`
   blocks. Mirror them into the datacenter registry and install from there, rather than adding
   another host to the proxy allowlist.
2. **Install Kyverno highly available** (three admission-controller replicas).
3. **Apply the policy with `validationActions: [Audit]`** and read the PolicyReports
   (`oc get policyreports -A`) for a sprint. Add missing approved repositories, or `PolicyException`s
   for named teams.
4. **Switch to `validationActions: [Deny]`.**
5. Keep the runbook's verification test 9, which proves the node-level backstop, and add a Kyverno
   test: `oc run t3 --image=quay.io/libpod/alpine:latest` in an application namespace must be
   refused at admission.

**Without Kyverno:** the same rule can be a built-in Kubernetes `ValidatingAdmissionPolicy`, which
OpenShift ships and Red Hat supports, as the catalog policies in
[`../catalog-policies/`](../catalog-policies/) already are. Kyverno adds PolicyReports, exceptions and
image signature checks on top.

## References

- [R8] `registrySources` applies "when accessing images for builds and pods":
  [`modules/images-configuration-parameters.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/images-configuration-parameters.adoc)
- [R9] "all registries, including `registry.redhat.io`, `quay.io`, and the default OpenShift image
  registry, are blocked unless explicitly listed":
  [`snippets/allowed-registries-warning.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/snippets/allowed-registries-warning.adoc)
- [R3] "Registries not in your allowlist are blocked":
  [`modules/images-configuration-allowed.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/images-configuration-allowed.adoc)
- Kyverno 1.19.1 `ValidatingPolicy` CRD and images: the release's
  [`install.yaml`](https://github.com/kyverno/kyverno/releases/download/v1.19.1/install.yaml)
