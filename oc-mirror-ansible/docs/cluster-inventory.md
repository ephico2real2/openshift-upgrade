# Cluster inventory cheat sheet

These commands read what a cluster uses today: its version, its mirror configuration, its catalogs, what the catalogs
serve, and the installed operators.
They change nothing. Run them before you mirror for a cluster, so that the registry gets everything the cluster needs.

Run them on a host where `oc` is logged in to the cluster. The user must be able to read cluster objects, for example
with the `cluster-reader` role. To make sure that you are logged in, run `oc whoami`.

What to take to the lab: only the organization names, the package lists of sections 3 and 4, and the operator list. The lab does not need host names, image
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

## 4. What the catalogs serve

A catalog serves operators that nobody installed yet. A cluster filled by oc-mirror v1 has a catalog that holds only
what was mirrored. After a move to a new registry, the cluster must keep the same choice of operators. Thus the new
mirror needs every package that the catalogs serve today, not only the installed ones.

OLM shows each package of each catalog as a PackageManifest object. Count the packages of each catalog:

```bash
oc get packagemanifests -n openshift-marketplace -o custom-columns=CATALOG:.status.catalogSource --no-headers | sort | uniq -c
```

List each channel of each package, with the version at the head of the channel:

```bash
oc get packagemanifests -n openshift-marketplace -o go-template='{{range .items}}{{$c := .status.catalogSource}}{{$p := .metadata.name}}{{$d := .status.defaultChannel}}{{range .status.channels}}{{$c}} {{$p}} {{.name}} {{.currentCSVDesc.version}}{{if eq .name $d}} default{{end}}{{"\n"}}{{end}}{{end}}' | sort
```

Each line is `<catalog> <package> <channel> <head version>`. The word `default` marks the default channel of the
package. The command uses a Go template, which `oc` has built in, so it needs no `jq`.

The head version is the newest version in the channel. To see every version that the catalog serves in a channel, list
the entries:

```bash
oc get packagemanifests -n openshift-marketplace -o go-template='{{range .items}}{{$p := .metadata.name}}{{range .status.channels}}{{$p}} {{.name}}:{{range .entries}} {{.version}}{{end}}{{"\n"}}{{end}}{{end}}' | sort
```

Each line is `<package> <channel>: <version> <version> ...`. The oldest version of a line is the `minVersion` that keeps
the whole channel in the new mirror. If the output shows only the package and the channel, the OLM of this cluster does
not fill `entries`. Then use the head version.

### From a bastion, without the cluster

`oc-mirror` can read a catalog image directly from its registry, with no cluster. The commands are in the
[oc-mirror README](https://github.com/openshift/oc-mirror/blob/main/README.md), "List Subcommand". Take the catalog
image from section 3, and set the paths on the bastion:

```bash
CATALOG=<registry host>:8443/<organization>/redhat/redhat-operator-index:v4.18
AUTH_FILE=/run/user/0/containers/auth.json
```

`AUTH_FILE` must hold a login for the registry of `CATALOG`, and the host must trust its CA. Then list the packages,
the channels of one package, and the versions of one channel:

```bash
oc-mirror --v2 list operators --authfile "$AUTH_FILE" --catalog="$CATALOG"
oc-mirror --v2 list operators --authfile "$AUTH_FILE" --catalog="$CATALOG" --package=<package>
oc-mirror --v2 list operators --authfile "$AUTH_FILE" --catalog="$CATALOG" --package=<package> --channel=<channel>
```

`oc-mirror` downloads the catalog image to its cache first. The cache is in `$HOME` unless you give `--cache-dir`.

In the lab, the same commands read Red Hat's own catalogs. To list the catalogs of a release, and then the packages of
the Red Hat catalog for 4.18, run:

```bash
oc-mirror --v2 list operators --authfile "$AUTH_FILE" --catalogs --version=4.18
oc-mirror --v2 list operators --authfile "$AUTH_FILE" --catalog=registry.redhat.io/redhat/redhat-operator-index:v4.18
```

In the lab, on 2026-11-22, the first command printed:

```text
Available OpenShift OperatorHub catalogs:
OpenShift 4.18:
registry.redhat.io/redhat/redhat-operator-index:v4.18
registry.redhat.io/redhat/certified-operator-index:v4.18
registry.redhat.io/redhat/community-operator-index:v4.18
registry.redhat.io/redhat/redhat-marketplace-index:v4.18
```

Without `--authfile`, `oc-mirror` reads `${XDG_RUNTIME_DIR}/containers/auth.json`, as its `--help` shows. For root,
that is the same file as `AUTH_FILE` above.

A package that the cluster's catalog serves must also be in Red Hat's catalog of the same version. Otherwise the new
mirror cannot get it from Red Hat.

### If oc-mirror refuses the catalog

`oc-mirror` checks the update paths of every package before it lists anything. If one package fails the check, it
refuses the whole catalog. In the lab, on 2026-11-22, `redhat-operator-index:v4.18` failed this way:

```text
[ERROR]  : [Executor] failed to load catalog: failed to load catalog model: invalid index:
└── invalid package "skupper-operator":
    ├── invalid channel "alpha":
    │   └── channel contains one or more stranded bundles: skupper-operator.v1.2.2, ...
```

The same error on the 4.20 catalog is [skupper-operator issue #68](https://github.com/skupperproject/skupper-operator/issues/68).
`oc-mirror` has no flag that skips one package. Instead, copy the catalog files out of the image and read them with
[`../scripts/catalog-inventory.py`](../scripts/catalog-inventory.py). The script reports a problem on the line of its
channel and goes on.

On the host, set the paths:

```bash
CATALOG_IMAGE=registry.redhat.io/redhat/redhat-operator-index:v4.18
OUT=/registry-data/oc-mirror/catalogs/redhat-operator-index-v4.18
mkdir -p "$OUT"
```

Copy the files out of the image. `podman create` makes a container that does not start, so the image needs no tools of
its own:

```bash
podman pull "$CATALOG_IMAGE"
podman image inspect "$CATALOG_IMAGE" --format '{{ index .Config.Labels "operators.operatorframework.io.index.configs.v1" }}'
ctr=$(podman create "$CATALOG_IMAGE")
podman cp "$ctr":/configs "$OUT/configs"
podman rm "$ctr"
ls "$OUT/configs" | wc -l
```

The `inspect` command must print `/configs`, the folder of the catalog files in the image. If it prints another path,
use that path in `podman cp`. `ls` counts the packages, one folder each.

Then list the packages, channels and versions:

```bash
python3 /root/openshift-upgrade/oc-mirror-ansible/scripts/catalog-inventory.py "$OUT/configs" > "$OUT/inventory.txt"
grep '^skupper-operator ' "$OUT/inventory.txt"
grep ' problem=' "$OUT/inventory.txt" | cut -d' ' -f1,2,6 | cut -c1-120
```

Each line of `inventory.txt` is `<package> <channel> default|- head=<version> versions=<v1>,<v2>,...`. A channel that
fails the check of `oc-mirror` also gets `problem=stranded:...`, `problem=multiple-heads:...`, `problem=no-head` or
`problem=cycle:...`. The script uses the rules of `Channel.Head` and `validateReplacesChain` in
[operator-registry](https://github.com/operator-framework/operator-registry/blob/main/alpha/model/model.go), the
library that loads catalogs for `oc-mirror`. It reads `catalog.json` and `catalog.yaml` files. It needs Python 3 and
PyYAML, which `ansible-core` installs.

## 5. Installed operators

```bash
oc get subscriptions.operators.coreos.com -A -o custom-columns=NS:.metadata.namespace,NAME:.spec.name,CHANNEL:.spec.channel,SOURCE:.spec.source,CSV:.status.installedCSV
```

Print the package, the channel and the installed version of each operator, the three values that the catalog run needs:

```bash
oc get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.name}{" "}{.spec.channel}{" "}{.status.installedCSV}{"\n"}{end}' | while read -r ns pkg channel csv; do printf '%s %s %s\n' "$pkg" "$channel" "$(oc get clusterserviceversion "$csv" -n "$ns" -o jsonpath='{.spec.version}')"; done | sort -u
```

Each line is `<package> <channel> <version>`, for example `cluster-logging stable-6.2 6.2.3`. The version comes from the
ClusterServiceVersion (CSV) of the operator, not from the CSV name.

An installed operator must also be in the list of section 4. If it is not, the catalog that installed it no longer
serves it, and the new mirror needs it from Red Hat's catalog.

## Use the results in the lab

| Result | Where it goes |
|---|---|
| The version from section 1 | `ocp_version` of `playbook.yml` (the default is `4.18.17`) |
| The organization from section 2 | `mirror_namespace` in `vars/env-<name>.yml` |
| The lines from sections 4 and 5 | `packages` in `vars/catalogs-<group>.yml`, one entry per package. Section 4 gives every package that the catalogs serve. Section 5 gives the version that each installed operator needs at least |

A line `cluster-logging stable-6.2 6.2.3` becomes this entry:

```yaml
      - name: cluster-logging
        channels:
          - name: stable-6.2
            minVersion: "6.2.3"
```

`minVersion` set to the installed version keeps that version and every later version of the channel in the mirror. The
cluster can then stay where it is, or update. For a package that is not installed, use the oldest version of its
channel from section 4. A package with only its name and no channel mirrors the head version of every channel. The
table "Choosing what each package entry mirrors" in [`catalog-mirroring-guide.md`](catalog-mirroring-guide.md) gives
each form and what it mirrors.

The `oc` commands were tested on a kind cluster with stand-in versions of the OpenShift and OLM objects, not on an
OpenShift cluster. For `oc-mirror --v2 list operators`, `--catalogs --version=4.18` ran in the lab with `oc-mirror` 2.0.0
and gave the output above. The form with `--catalog` failed on `redhat-operator-index:v4.18`, as "If oc-mirror refuses the catalog" shows.

`catalog-inventory.py` was tested in a Rocky Linux 9 container (Python 3.9.25, PyYAML 5.4.1). Four test channels gave
the result that `Channel.Head` and `validateReplacesChain` require: a valid channel, a stranded bundle, two heads and a
cycle. The public catalog `quay.io/operatorhubio/catalog` was copied out with `podman cp`. From its YAML files, the script
read 475 packages and 741 channels, and found 5 channels with stranded bundles. It did not run on the Red Hat catalog yet, and
`opm validate` was not used as a second check.
