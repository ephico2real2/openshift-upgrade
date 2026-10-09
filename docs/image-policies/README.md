# Image policies: which images application pods may use

Opening `quay.io` through the proxy opens anyone's public images there. Two controls limit what runs,
and we use both:

| | `allowedRegistries` (runbook phase 3) | Kyverno policy (this folder) |
|---|---|---|
| Where it is enforced | CRI-O on every node, at every image pull | API server admission, when a pod or controller is created or changed |
| What it covers | Every pull: platform and application pods, static pods, builds ("for builds and pods" [R8]), `crictl pull` on a node | Pods and their controllers in application namespaces; platform namespaces are excluded |
| How strict it can be | Must include everything the **platform** pulls, including `quay.io/openshift-release-dev`; "all registries … are blocked unless explicitly listed" [R9] | Can be stricter for applications: they never need the release repository |
| Scope | One list for the whole cluster | A list in a ConfigMap for application namespaces, with Kyverno `PolicyException`s for a named team |
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

Restricting images to approved registries is a standard Kyverno use case. The Kyverno policy library
ships it as `restrict-image-registries`, and as `advanced-restrict-image-registries`, which keeps the
allowed list in a ConfigMap in the cluster ([kyverno/policies](https://github.com/kyverno/policies),
`best-practices-vpol/` and `other-vpol/`). We use the second pattern:

- [`allowed-image-registries.yaml`](allowed-image-registries.yaml): the **list**, ConfigMap
  `kyverno/allowed-image-registries`, one registry or registry/path prefix per line. Adding a
  registry means editing this list, not the policy. The internal names are illustrations:
  `registry.example.com` stands for the enterprise registry, whatever it is (Artifactory, a GitLab
  container registry, Harbor or Quay), and `registry-dc1.example.com:8443` for the datacenter's
  oc-mirror registry, kept until runbook phase 9. Put each cluster's real names there, and add what
  the phase 1 inventory shows applications pull from.
- [`kyverno-workload-image-repos.yaml`](kyverno-workload-image-repos.yaml): the **policy**, a Kyverno
  `ValidatingPolicy` (CEL; Kyverno 1.19 deprecates `kyverno.io/v1` `ClusterPolicy`) that reads the
  list with `resource.Get`.

Our changes to the library policy:

| Change | Why |
|---|---|
| List in the `kyverno` namespace, not `default` | Only cluster admins can change it |
| Each entry matched up to a `/` | The library's plain prefix match lets `registry.redhat.io` also allow `registry.redhat.io.evil.example.com/…`; our test proves the difference |
| Platform namespaces skipped (`openshift`, `openshift-*`, `kube-*`, `default`, `kyverno`) | The platform's images are governed by `allowedRegistries`; users cannot create `openshift-`/`kube-` namespaces |
| `failurePolicy: Fail` | With the ConfigMap missing, the policy errors; failing closed refuses the pod instead of letting it through |
| No per-namespace annotation list | Exceptions for a named team go through a Kyverno `PolicyException`, which cluster admins own |

Kyverno generates the same rule for Deployments, StatefulSets, DaemonSets, Jobs and CronJobs, so a
bad image is refused at `oc apply`. It does so only while the policy matches plain `pods`, so debug
containers added to a running pod (`oc debug`, ephemeral containers) are not checked by this policy;
`allowedRegistries` still applies to their pulls.

## Test

```bash
KYVERNO=/path/to/kyverno ./test.sh     # kyverno CLI v1.19.1, offline: kyverno test .kyverno-test
```

`test.sh` copies the real ConfigMap into the test context, so the test runs against the list we
apply. The fixtures in [`.kyverno-test/resource.yaml`](.kyverno-test/resource.yaml) are named after
the expected result. Recorded on 2026-10-08:

- 12 of 12 as expected: three allowed pods, five denied pods (Docker Hub short name, public
  `quay.io`, the release repository, a look-alike host, a bad init container), one skipped platform
  pod, and an allowed Deployment, a denied Deployment and a denied CronJob.
- Each deliberate break was caught: `quay.io` swapped into the list (4 cases fail), the `/` matching
  removed (the look-alike host gets through), and a broken CEL expression (the script fails; `kyverno
  test` alone counts an invalid policy as passing, so the script checks every row's reason).
- With no ConfigMap, the CLI reports an error for the pod, not a pass.

Limits: offline only. A kind cluster could not run pods in the session's container, so the policy
has not run against an API server, and not on OpenShift.

## Rolling it out

1. **Mirror Kyverno's images.** They come from `reg.kyverno.io/kyverno/`, which `allowedRegistries`
   blocks. Mirror them into the datacenter registry and install from there, rather than adding
   another host to the proxy allowlist.
2. **Install Kyverno highly available** (three admission-controller replicas).
3. **Apply the ConfigMap, then the policy with `validationActions: [Audit]`**, and read the PolicyReports
   (`oc get policyreports -A`) for a sprint. Add missing registries to the ConfigMap, or
   `PolicyException`s for named teams.
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
- Kyverno policy library, `advanced-restrict-image-registries` and `restrict-image-registries`:
  [kyverno/policies](https://github.com/kyverno/policies) (read at commit `ec478cb`, 2026-09-30)
- Kyverno 1.19.1 `ValidatingPolicy` CRD and images: the release's
  [`install.yaml`](https://github.com/kyverno/kyverno/releases/download/v1.19.1/install.yaml)
