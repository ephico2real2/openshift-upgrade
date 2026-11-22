# Cluster inventory cheat sheet

These commands read what a cluster uses today: its version, its mirror configuration, its catalogs and its operators.
They change nothing. Run them before you mirror for a cluster, so that the registry gets everything the cluster needs.

Run them on a host where `oc` is logged in to the cluster. The user must be able to read cluster objects, for example
with the `cluster-reader` role. To make sure that you are logged in, run `oc whoami`.

What to take to the lab: only the organization names and the operator list. The lab does not need host names, image
digests or any secret.

## 1. Cluster version

```bash
oc get clusterversion
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
```

The second command prints only the version, for example `4.18.17`. The release run must mirror this version.

## 2. Mirror configuration

A cluster filled by oc-mirror v1 has ImageContentSourcePolicy objects (ICSP). A cluster filled by oc-mirror v2 has
ImageDigestMirrorSet (IDMS) and ImageTagMirrorSet (ITMS) objects. Look for all three:

```bash
oc get imagecontentsourcepolicy
oc get imagedigestmirrorset,imagetagmirrorset
```

List each mirror on its own line:

```bash
oc get imagecontentsourcepolicy -o jsonpath='{range .items[*].spec.repositoryDigestMirrors[*].mirrors[*]}{@}{"\n"}{end}' | sort -u
oc get imagedigestmirrorset -o jsonpath='{range .items[*].spec.imageDigestMirrors[*].mirrors[*]}{@}{"\n"}{end}' | sort -u
oc get imagetagmirrorset -o jsonpath='{range .items[*].spec.imageTagMirrors[*].mirrors[*]}{@}{"\n"}{end}' | sort -u
```

Each line has the form `<registry host>:<port>/<organization>/<repository>`. Do not use `{.mirrors[*]}` as the last
part of the `range`. For an entry with two mirrors, it prints both on one line, and `sort -u` then cannot remove
duplicates.

To get only the organization names, the part after the host, run:

```bash
oc get imagecontentsourcepolicy -o jsonpath='{range .items[*].spec.repositoryDigestMirrors[*].mirrors[*]}{@}{"\n"}{end}' | cut -d/ -f2 | sort -u
```

The playbooks call this name `mirror_namespace`. If oc-mirror v1 filled this path, it is the v1 path. The playbooks must
never push to it on that registry: see "Existing registries, new path" in [`../../docs/PREREQUISITES.md`](../../docs/PREREQUISITES.md).

To see where the images come from, list the sources:

```bash
oc get imagecontentsourcepolicy -o jsonpath='{range .items[*].spec.repositoryDigestMirrors[*]}{.source}{"\n"}{end}' | sort -u
```

The Red Hat registries are `registry.redhat.io`, `quay.io` and `registry.connect.redhat.com`. The Red Hat runs do not
mirror images from any other source. Before a cluster moves to a new registry, those images also need a place in it.

## 3. Catalogs

```bash
oc get catalogsource -n openshift-marketplace -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image
```

The image tag shows the OpenShift version of each catalog, for example `redhat-operator-index:v4.18`.

## 4. Operators

```bash
oc get subscriptions.operators.coreos.com -A -o custom-columns=NS:.metadata.namespace,NAME:.spec.name,CHANNEL:.spec.channel,SOURCE:.spec.source,CSV:.status.installedCSV
```

Print the package, the channel and the installed version of each operator, the three values that the catalog run needs:

```bash
oc get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.name}{" "}{.spec.channel}{" "}{.status.installedCSV}{"\n"}{end}' | while read -r ns pkg channel csv; do printf '%s %s %s\n' "$pkg" "$channel" "$(oc get clusterserviceversion "$csv" -n "$ns" -o jsonpath='{.spec.version}')"; done | sort -u
```

Each line is `<package> <channel> <version>`, for example `cluster-logging stable-6.2 6.2.3`. The version comes from the
ClusterServiceVersion (CSV) of the operator, not from the CSV name.

## Use the results in the lab

| Result | Where it goes |
|---|---|
| The version from section 1 | `ocp_version` of `playbook.yml` (the default is `4.18.17`) |
| The organization from section 2 | `mirror_namespace` in `vars/env-<name>.yml` |
| The lines from section 4 | `packages` in `vars/catalogs-<group>.yml`, one entry per package |

A line `cluster-logging stable-6.2 6.2.3` becomes this entry:

```yaml
      - name: cluster-logging
        channels:
          - name: stable-6.2
            minVersion: "6.2.3"
```

`minVersion` set to the installed version keeps that version and every later version of the channel in the mirror. The
cluster can then stay where it is, or update.

These commands were tested on a kind cluster with stand-in versions of the OpenShift objects, not on an OpenShift
cluster.
