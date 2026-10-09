# Prerequisites: mirroring bastions and the three registries

| | |
|---|---|
| Date | 2026-10-07 |
| Status | Proposed. No host is built yet; hostnames below are examples |
| Researched | `quay/mirror-registry` (`main` and tags to `v2.0.12`, 2026-08-27); `openshift/openshift-docs` `enterprise-4.18` and `enterprise-4.22`; `quay/quay-docs` `redhat-3.18`; `openshift/oc` and `openshift/oc-mirror` `release-4.22` |
| Needed by | Step 1 ([`oc-mirror-ansible/`](../oc-mirror-ansible/README.md)) and Step 3 ([`quay-onprem/`](quay-onprem/README.md)) to run at all; Step 2 ([`enterprise-proxy/`](enterprise-proxy/README.md)) for the lab registry and the transition. Overview: [`SOLUTIONS.md`](SOLUTIONS.md) |

Before any mirroring run, we need new hosts. **One mirroring bastion in each datacenter**, where every
Ansible and oc-mirror command runs, and **three registries**: one for the lab and one production
registry in each datacenter. They replace the three old registries we mirror into today, one for one. This page
says what we run now, what replaces it, and what each host needs before the guides can be followed.

## Summary

| Decision | Recommendation | Why |
|---|---|---|
| Registry software for Step 1 | **mirror registry for Red Hat OpenShift 2.0.x**, a fresh install on each of the three registry hosts | The current Red Hat release; it bundles Quay 3.12 and replaces PostgreSQL with SQLite |
| Old registries (three) | Keep each running until every cluster on it has moved to its new counterpart; then retire it. Do not upgrade them in place. Meanwhile each can also take oc-mirror v2 pushes **on a new path** | We are moving to new hosts and new names anyway, and only 1.3 → 2.x is a documented upgrade (see below). A new path lets clusters use v2 content before their new registry exists |
| Existing registries | Every push can target an existing registry too, on a new path that oc-mirror v1 never wrote to; the v1 path is protected | See "Existing registries, on a new path" |
| Content in the new registries | **Mirror again from Red Hat with oc-mirror v2**: each bastion downloads to disk once (mirror-to-disk, with a persistent cache), then pushes that archive into lab and production (disk-to-mirror) | Red Hat documents no way to copy mirror registry data between hosts; the cache means later runs fetch only what changed; one archive gives lab and production the same content |
| Operating system | **RHEL 9** for the bastions and the registry hosts | The mirror registry supports "RHEL 8 and 9"; `oc` and `oc-mirror` 4.22 are built for RHEL 8 and RHEL 9 only. RHEL 10 is not documented for either |
| Bastions | One per datacenter, RHEL 9, reaching Red Hat only through the enterprise proxy | Each bastion fills the registries in its own datacenter; no cross-datacenter pushes |

## What we run today

| Item | Today | Source |
|---|---|---|
| Registries | **Three** Red Hat **mirror registries for Red Hat OpenShift**, the trimmed-down Quay installed with `mirror-registry install`, each **more than three years old** (team report, 2026-10-07) | |
| Their release | Older than October 2023, so mirror registry **1.0 to 1.3.x**, bundling **Quay 3.6 to 3.8**: 1.0 shipped in January 2022, 1.3.0 on 20 February 2023, 1.3.10 on 7 December 2023 | Mirror registry release notes (`enterprise-4.13` `modules/mirror-registry-release-notes.adoc`); `quay/mirror-registry` tags |
| How it is filled | **oc-mirror v1** (team report), run by hand: the manual sync described in [`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md). Step 1 replaces it with oc-mirror v2 and Ansible | |
| On the clusters | v1 output: `ImageContentSourcePolicy` (ICSP) objects, CatalogSources and release-signature ConfigMaps | Red Hat 4.18, "Mirroring images for a disconnected installation using the oc-mirror plugin" |
| Hosts | Three registry hosts, assumed one per role: lab, DC1 production, DC2 production (to confirm). The exact version, OS and disk of each are to be recorded with the commands below. Mirror registry 1.x before 1.3 was documented for RHEL 8 only; 1.3.0 added RHEL 9 | 1.3.0 release notes: "now supported on RHEL 9 installations" |

Record each old registry's facts before anything changes. On each of the three registry hosts:

```bash
podman ps --format '{{.Names}}  {{.Image}}'        # quay-app, quay-redis, quay-postgres (1.x) and their image tags
podman images | grep -E 'quay|postgres|redis|pause'
cat /etc/redhat-release
df -h; podman volume ls                              # quay-storage, pg-storage (1.3+) or /etc/quay-install (older)
systemctl list-units 'quay-*'
```

The Quay image tag gives the release (expect 3.6, 3.7 or 3.8 on registries this old): Quay 3.6 is mirror registry 1.0–1.1, 3.7 is 1.2, 3.8 is 1.3, and
3.12 is 2.0 (from the `.env` image pins of each `quay/mirror-registry` tag).

### What the old oc-mirror v1 process means for us

Red Hat's 4.18 page for the tool we used ([Mirroring images for a disconnected installation using
the oc-mirror plugin](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/installing-mirroring-disconnected),
source `disconnected/installing-mirroring-disconnected.adoc`, `enterprise-4.18`) describes
oc-mirror **v1**: "The oc-mirror v1 plugin is deprecated … migrate to the supported v2 plugin and
use the `--v2` flag."

| v1, as the old registries were filled | v2, as the new registries are filled | What it means for us |
|---|---|---|
| `ImageSetConfiguration` `mirror.openshift.io/v1alpha2` with a required `storageConfig` for metadata: "You must use the same storage backend every time" | `v2alpha1`, no `storageConfig`; state lives in the cache and each archive's `working-dir` | The old metadata is not reused. The new registries start clean |
| Mirror-to-disk writes `mirror_seq1_000000.tar`; disk-to-mirror takes `--from=<tar>` | `oc mirror -c <isc> file://<dir> --v2`, then `oc mirror -c <isc> --from file://<dir> docker://<registry> --v2` | Same idea, new commands; the playbooks run them (`m2d`, `d2m`) |
| Incremental: "you only download the images that changed since the last time" | Incremental through the cache, used by mirror-to-disk and disk-to-mirror | Why we keep one cache per bastion |
| **Prunes** images dropped from the ImageSet ("Replacing by `stable-4.13` prunes all the images of `stable-4.12`"); `--dry-run` writes `pruning-plan.json` | Never prunes on its own; deleting is a separate `oc mirror delete` workflow | Old versions stay in the new registries until someone deletes them on purpose |
| Writes ICSP, CatalogSources and `release-signatures/` under `oc-mirror-workspace/results-*` | Writes IDMS, ITMS, CatalogSources, ClusterCatalogs, signature ConfigMaps and `updateService.yaml` under `working-dir/cluster-resources` | The clusters carry ICSPs today; moving to the new registries adds IDMS/ITMS and later removes the ICSPs (cutover below) |
| "Use the latest available version of the oc-mirror plugin regardless of which versions of OpenShift you need to mirror"; Quay "version 3.6 or later" | Same | Install the newest `oc-mirror` on the bastions; mirror registry 2.0 is Quay 3.12 |
| "any further updates to the target mirror registry must be made by using the oc-mirror plugin" | Same | Nothing else writes into the new registries |

### What changed in the new release

| | 1.3 (newest 1.x, 1.3.11, April 2024) | 2.0 (2.0.0 September 2024; newest 2.0.12, August 2026) |
|---|---|---|
| Quay | 3.8.x | 3.12.x (2.0.11: "Red Hat Quay 3.12.18"; tag 2.0.12 pins 3.12.21) |
| Database | PostgreSQL 10 container | **SQLite**: "the internal database has been upgraded from PostgreSQL to SQLite … data is now stored on the `sqlite-storage` Podman volume by default" |
| Writers | | "The worker count is set to `1` because multiple writes are not allowed in SQLite" |
| Install | `mirror-registry install` (embedded Ansible), systemd units for a Podman pod | Same installer and units; new `--sqliteStorage` flag |

Sources: `docs422 modules/mirror-registry-release-notes-2-0.adoc`, enterprise-4.13
`modules/mirror-registry-release-notes.adoc`, `quay/mirror-registry` `.env` per tag.

### Upgrade in place, or a new setup?

- **What Red Hat documents:** `./mirror-registry upgrade -v` from 1.3 to 2.x, migrating PostgreSQL
  to SQLite, with "intermittent downtime" and a PostgreSQL backup kept under
  `$HOME/quay-install/quay-postgres-backup/` (`modules/mirror-registry-localhost-update.adoc`).
  Red Hat's CI tests that path from 1.3.10. **No path from 1.0–1.2 straight to 2.x is documented.**
- **Our three are older than October 2023**, so each is 1.0, 1.1, 1.2 or an early 1.3. Only an
  early 1.3 has a documented path, and even that goes through PostgreSQL-to-SQLite migration on a
  host that may still run RHEL 8.
- **Our decision: a new setup.** It is the simpler path whichever 1.x each one runs:
  - the new registries are on new RHEL 9 hosts with new names, one for each old one;
  - their content is mirrored fresh by oc-mirror v2, which also writes the IDMS, ITMS, signature
    ConfigMap and Update Service files the clusters need;
  - the old registries keep serving the clusters, untouched, until each cluster has switched.
- If someone proposes upgrading an old host instead: only from 1.3, with a backup first, and it
  leaves that registry on its old host and OS.

### Limits of the mirror registry, from Red Hat

These shape how far the three registries can be pushed:

- "not a highly-available registry and only local file system storage is supported";
- "not intended to be a substitute for a production deployment of Red Hat Quay";
- "only supported for hosting images that are required to install a disconnected OpenShift
  cluster, such as Release images or Red Hat Operator images"; "Content built by customers should
  not be hosted";
- "Using the mirror registry … with more than one cluster is discouraged because multiple clusters
  can create a single point of failure … Instead, use [it] to install a cluster that can host a
  production-grade, highly-available registry such as Red Hat Quay."

The oc-mirror v2 prerequisites add: "Mirror registries must be operated in a highly available
manner, ensuring their availability aligns with the production availability of your OpenShift
Container Platform clusters" (`modules/oc-mirror-v2-prerequisites.adoc`). A single-host mirror
registry cannot meet that on its own.

Source: `docs422 modules/mirror-registry-introduction.adoc` and its assembly. **The last point
matters for the two production registries:** if each one serves several clusters, Red Hat's answer
is full Red Hat Quay, which is Step 3 ([`quay-onprem/`](quay-onprem/README.md)). Until then, run one
production registry per datacenter, keep it backed up, and keep the lab registry as the place new
content is tried first.

## Target layout

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/prerequisites/topology.dark.png">
  <source srcset="diagrams/prerequisites/topology.light.png">
  <img alt="Target layout. In datacenter 1 a mirroring bastion reaches Red Hat only through the enterprise proxy and pushes over TCP 8443 to two mirror registries: the lab registry and the datacenter 1 production registry. In datacenter 2 its own bastion does the same for the datacenter 2 production registry. Lab clusters pull from the lab registry and each datacenter's production clusters pull from their own registry. Three old 1.x mirror registries, one per role, keep serving until their clusters have switched, then they are retired; meanwhile each datacenter's bastion may also push the same content into them on a new path, never into the oc-mirror v1 path. All new hosts run RHEL 9." src="diagrams/prerequisites/topology.light.png">
</picture>

*Proposed: none of these hosts exists yet. Each bastion pushes only to registries in its own
datacenter. Each old registry stays until the last cluster on it has switched.*

```text
             DATACENTER 1                                    DATACENTER 2
BASTION      mirror-bastion-dc1 (RHEL 9)                     mirror-bastion-dc2 (RHEL 9)
             Ansible + oc-mirror v2 + Vault                  Ansible + oc-mirror v2 + Vault
               | 443 via the enterprise proxy -> Red Hat       | 443 via the enterprise proxy -> Red Hat
               | 8443 direct                                   | 8443 direct
REGISTRIES   registry-lab   registry-dc1                     registry-dc2
             (mirror registry 2.0.x on RHEL 9, one host each)
CLUSTERS     lab clusters   production clusters, DC1         production clusters, DC2
OLD          mirror-old-lab, mirror-old-dc1 (DC1) and mirror-old-dc2 (DC2), 1.x, serving until their clusters
             have switched, then retired; optional: each datacenter's bastion pushes into them on a new path (ocp4v2)
```

| Host (example name) | Datacenter | Role | Fills / serves |
|---|---|---|---|
| `mirror-bastion-dc1.example.com` | DC1 | Mirroring bastion: all Ansible, `oc-mirror`, `oc` and `skopeo` commands | Pushes to `registry-lab` and `registry-dc1` |
| `mirror-bastion-dc2.example.com` | DC2 | Mirroring bastion | Pushes to `registry-dc2` |
| `registry-lab.example.com:8443` | DC1 (to confirm) | Lab registry; new content lands here first | Lab clusters |
| `registry-dc1.example.com:8443` | DC1 | Production registry | Production clusters in DC1 |
| `registry-dc2.example.com:8443` | DC2 | Production registry | Production clusters in DC2 |
| `mirror-old-lab`, `mirror-old-dc1` (DC1), `mirror-old-dc2` (DC2) | as today | The three old 1.x registries | Today's clusters, until each has switched; then retired |

**Which datacenter holds the lab** is to confirm; the table assumes DC1. If the lab is elsewhere,
the bastion of that datacenter fills it.

### Order of a mirroring cycle

Each bastion downloads once and pushes the same archive into every registry it fills. The
playbooks do this with `oc_mirror_workflow=m2d` (Red Hat → archive) and `oc_mirror_workflow=d2m`
(archive → one registry).

| Step | DC1 bastion | DC2 bastion |
|---|---|---|
| 1 | Dry-run the download; size it; agree the pinned versions (release guide, "Mirroring an upgrade path") | |
| 2 | **Download** (`m2d`) into `/data/oc-mirror/archive-<run>`, filling the cache | |
| 3 | **Push** (`d2m`) into `registry-lab`; update a lab cluster with that content | |
| 4 | **Push** the same archive into `registry-dc1` | **Download** with the same pinned ImageSet into its own archive and cache, then **push** into `registry-dc2` |
| 5 | Production clusters in DC1 apply `registry-dc1`'s `cluster-resources` | Production clusters in DC2 apply `registry-dc2`'s |

- **Same content in lab and DC1:** one archive, pushed twice.
- **DC2 downloads for itself** (team decision, 2026-10-07): no copy between datacenters. Release
  images are pinned by digest, so DC2 gets the same releases. Operator catalogs are built from the
  catalog image of the day, so run DC2's download soon after DC1's and compare the catalog digests
  before pushing:

  ```bash
  skopeo inspect --format '{{.Digest}}' docker://registry.redhat.io/redhat/redhat-operator-index:v4.18
  ```

- **Each push writes that registry's cluster resources** to
  `/data/oc-mirror/cluster-resources/<archive>-<registry>-<path>/`. Hand a cluster only the folder of the
  registry it pulls from.

### The cache

The cache is what makes the road from 4.18 to 4.22 cheap: each download fetches only what earlier
downloads have not.

- Red Hat: "The oc-mirror plugin uses the cache in the `mirror-to-disk` and `disk-to-mirror`
  workflows … to perform incremental mirroring and avoids remirroring unchanged images". It "only
  contains data up to the last successful mirroring operation", so a failed run resumes from there
  (`modules/oc-mirror-about-cache-and-workspace-dirs.adoc`).
- **One cache per bastion, on `/data`, for the whole road.** Never delete it between runs: "If you
  delete or corrupt the cache directory, the oc-mirror plugin pulls the image blobs and manifests
  again, which can force a full remirror". Do not edit an archive's `working-dir` either.
- **Back it up:** "Place the cache and workspace directories on reliable and backed-up storage."
- Straight registry-to-registry runs (`m2m`) skip the cache entirely: "does not use a cache,
  restarts from the beginning after a failure" (`modules/oc-mirror-workflows-table.adoc`). Keep
  them for small top-ups only.

### Existing registries, on a new path

A push (`d2m`) is not limited to the three new registries. The same archive can go into an
**existing registry**, such as one of the three old 1.x mirror registries or another registry we already run,
under a **new path**: the Quay organization `ocp4v2` (the playbooks' `mirror_namespace`), next to
the content oc-mirror v1 put there. Using the same organization on all six registries means the
IDMS/ITMS, CatalogSources and Update Service files differ only by host. The playbooks treat it as one more registry: its own Vault file, its own robot account,
its own `cluster-resources` folder (`<archive>-<registry>-<path>`).

Why do it:

- **Clusters can move to v2 content early.** They already trust that registry's CA and reach it
  through the firewall, so IDMS/ITMS, signatures and the Update Service graph can arrive before
  their new registry is built.
- **The v1 content stays as it is**, a fallback until the cluster's ICSPs are removed.

| Rule | Why |
|---|---|
| Push only to a path oc-mirror v1 never wrote to, e.g. `ocp4v2`. Put the v1 path in the vars file's `protected_targets`; the playbooks then refuse to push there | v1 "Prunes images from the target mirror registry that were excluded from the image set configuration since the previous execution". One tool per path keeps either from deleting the other's images |
| Stop the old v1 process, or keep it strictly on its own path | Red Hat: once oc-mirror fills a registry, "any further updates to the target mirror registry must be made by using the oc-mirror plugin" |
| The registry supports Docker v2-2 manifests; for Quay, 3.6 or later | Red Hat's prerequisite. All three old registries qualify: mirror registry 1.0 already ships Quay 3.6.1. Test on the oldest one first |
| Nested paths work on it | oc-mirror creates `<path>/openshift/release-images` and deeper. Run the push test (release guide, Step 5) on the new path; if it is refused, add `--max-nested-paths 2` to `oc_mirror_tuning` |
| Enough free disk on that host | The content lands a second time, beside v1's. Check `df -h` on the registry host against the dry-run counts |
| A write robot on the new organization for the bastion, a read robot for the clusters | Release guide, Step 5 |
| Its own Vault file per old registry: `vars/registry-old-lab.yml`, `-old-dc1`, `-old-dc2` | Template: `oc-mirror-ansible/vars/registry.yml.example`; each lists its own v1 path in `protected_targets` |

```bash
ansible-playbook playbook.yml --ask-vault-pass -e oc_mirror_workflow=d2m -e archive_name=archive-run-a \
  -e @vars/registry-old-dc1.yml      # target_registry_path: ocp4v2, protected_targets: [<old host>/<v1 path>]
```

**It is a bridge, not the end state.** Each old registry is still a single, non-HA 1.x host on Quay 3.6–3.8, a stream Red Hat no longer ships in the mirror registry. A
cluster that moves to it first and to its new registry later goes through two cutovers, and each
deletes mirror objects, which drains the nodes. Use it when a new registry is late, or to take a
cluster off v1 content sooner; otherwise move clusters straight to their new registry.

## Operating system: RHEL 9

| | RHEL 9 | RHEL 10 |
|---|---|---|
| Mirror registry 2.0 | Supported: "Red Hat Enterprise Linux (RHEL) 8 and 9 with Podman 3.4.2 or later and OpenSSL installed" | Not documented; no RHEL 10 reference in `quay/mirror-registry` |
| `oc`, `oc-mirror` 4.22 | Built for RHEL 9 (`oc.rhel9`, `oc-mirror.rhel9`) | No RHEL 10 build in `openshift/oc` or `openshift/oc-mirror` `release-4.22` |
| Full Red Hat Quay 3.18 (Step 3) | "Red Hat Enterprise Linux (RHEL) 9" | Not documented |
| Ansible | `ansible-core` in AppStream (2.14 for the RHEL 9 life cycle, per Red Hat's blog; not re-checked) | `ansible-core` in AppStream (version not confirmed) |
| Life cycle | GA May 2022; maintenance to 31 May 2032 | GA May 2025; maintenance to 31 May 2035 |
| OpenShift docs | The supported host for these tools | Mentioned in 4.22 only for MicroShift and as a Technology Preview cluster node image |

Sources: `docs422 modules/installing-mirroring-creating-registry-prerequisites.adoc`,
`oc-mirror-installing-plugin.adoc` ("You have installed the correct binary for the RHEL version that
you are using"), `quay-docs modules/con_quay_single_prereq.adoc`, the `release-4.22` Dockerfiles of
`openshift/oc` and `openshift/oc-mirror`; life-cycle dates from endoflife.date's RHEL data (Red Hat's
life-cycle page could not be fetched; confirm it).

**Use RHEL 9 (9.6 or later) on all five hosts.** Revisit RHEL 10 when Red Hat lists it for the
mirror registry and ships RHEL 10 `oc-mirror` builds. One RHEL 9 detail: from RHEL 9.5 (Podman 5)
rootless networking uses `pasta`, which can fail on hosts without a default route; the docs point to
"Configuring rootless Podman networking" for Podman 5.7 or later.

## Mirroring bastion (one per datacenter)

Everything the release and catalog guides do on "the mirror host" runs here.

| Item | Requirement | Note |
|---|---|---|
| OS | RHEL 9, registered (packages through the proxy) | See above |
| CPU, memory | 4 vCPU, 16 GB RAM | Our sizing for parallel pulls (`--parallel-images 4`); Red Hat gives no figure for an oc-mirror host |
| Disk | `/data` volume, **2 TB**, on backed-up storage | Holds the cache for the whole road plus the archives (each run's images again, as tar files) and `cluster-resources`. Red Hat: mirror-to-disk "uses an internal cache to resume after failures but requires additional disk space", and "might download several hundreds of gigabytes"; size from the dry-runs. Archives can be deleted once every registry the bastion fills has been pushed; the cache stays |
| Packages | `podman`, `skopeo`, `jq`, `tmux`, `ansible-core`, `git`, `openssl` | Release guide, Step 2 |
| Binaries | `oc` and `oc-mirror` from the RHEL 9 tarballs (`openshift-client-linux-amd64-rhel9-*.tar.gz`, `oc-mirror.rhel9.tar.gz`), the newest 4.22 | "Installing `oc` by using an RPM package is not supported on RHEL 9"; release guide, Step 3 |
| Proxy | `HTTPS_PROXY`/`NO_PROXY` set on the host, `NO_PROXY` listing `localhost,127.0.0.1` and this datacenter's registries | Release guide, Step 1 |
| Trust | The internal CA that signs the registries' certificates, and the proxy CA if it re-signs TLS | `/etc/pki/ca-trust/source/anchors/` |
| Secrets | Ansible Vault files: the Red Hat pull secret, and one robot account per registry this bastion pushes to | Below; release guide, "Ansible Vault in this project" |
| People | Named operators with `sudo` for setup only; runs as their own user | |

## Registry hosts (three)

| Item | Requirement | Source or note |
|---|---|---|
| OS | RHEL 9 with Podman 3.4.2 or later and OpenSSL | `installing-mirroring-creating-registry-prerequisites.adoc` |
| CPU, memory | "2 or more vCPUs", "8 GB of RAM" (minimum) | Same |
| Disk | "About 12 GB for OpenShift 4.22 release images, or about 358 GB for OpenShift 4.22 release images and OpenShift 4.22 Red Hat Operator images. Up to 1 TB per stream or more is suggested." Our path holds 4.18, 4.19, 4.20, 4.21 and 4.22 releases and filtered catalogs: **plan 2 TB, then size from the dry-runs** | Same; the 2 TB is our estimate |
| Storage location | A dedicated volume for `--quayRoot`, `--quayStorage` and `--sqliteStorage`; local file system only | `mirror-registry-flags.adoc`; "only local file system storage is supported" |
| Name | An FQDN that "must resolve through a DNS server"; `--quayHostname` "does not support installation with an IP address" | Flags reference |
| Port | TCP 8443 (the default `<targetHostname>:8443`) | Flags reference |
| TLS | A certificate from our internal CA for the FQDN, passed with `--sslCert` / `--sslKey` (otherwise one is generated) | Flags reference |
| Installer access | Key-based SSH from the bastion, when installing remotely | "Key-based SSH connectivity on the target host" |
| Backup | The `--quayRoot` directory and the storage volumes, on a schedule | Red Hat: if storage fails, "re-mirror … or reinstall mirror registry on more stable storage" |

### Install the mirror registry (each host)

Download `mirror-registry.tar.gz` (newest 2.0.x) from the OpenShift console **Downloads** page to
the bastion, then install remotely from the bastion:

```bash
./mirror-registry install -v \
  --targetHostname registry-dc1.example.com \
  --targetUsername <admin_user> \
  -k ~/.ssh/<key> \
  --quayHostname registry-dc1.example.com:8443 \
  --quayRoot /data/quay-install \
  --quayStorage /data/quay-storage \
  --sqliteStorage /data/sqlite-storage \
  --sslCert registry-dc1.crt --sslKey registry-dc1.key
```

The installer prints the `init` user's password at the end; put it straight into the team's
password vault. Then, in the registry's web UI (`https://registry-dc1.example.com:8443`):

1. Create the organization **`ocp4v2`**: the playbooks' `mirror_namespace`, the same on every registry.
2. Create a robot account with **write** to `ocp4v2` for the bastion, e.g. `ocp4v2+mirror`.
3. Create a robot account with **read** for the clusters' pull secret, e.g. `ocp4v2+pull`.
4. Run the push test in the release guide, Step 5.

### One Vault file per registry

The playbooks read `vars/credentials.yml`. For three registries, keep one encrypted file each and
pass it with `-e @`; extra variables win over `vars_files`:

```bash
ansible-vault create vars/registry-dc1.yml
#   target_registry_fqdn: "registry-dc1.example.com:8443"
#   target_registry_user: "ocp4v2+mirror"
#   target_registry_password: "<robot token>"

# download once (Red Hat credentials only), then push into each registry with its own file
ansible-playbook playbook.yml --ask-vault-pass -e oc_mirror_workflow=m2d -e archive_name=archive-run-a
ansible-playbook playbook.yml --ask-vault-pass -e oc_mirror_workflow=d2m -e archive_name=archive-run-a -e @vars/registry-lab.yml
ansible-playbook playbook.yml --ask-vault-pass -e oc_mirror_workflow=d2m -e archive_name=archive-run-a -e @vars/registry-dc1.yml
```

`vars/credentials.yml` must still exist, because the playbooks load it; keep the lab registry's
robot there and always pass the registry's own file with `-e @`. `vars/registry-*.yml` is in
`oc-mirror-ansible/.gitignore`.

## Network flows

| From | To, TCP port | Why |
|---|---|---|
| Bastion | Enterprise proxy → `quay.io` (+ CDN), `registry.redhat.io`, `api.openshift.com`, `registry.access.redhat.com`, `mirror.openshift.com`, **443** | Releases, catalogs, update graph, base image, `oc`/`oc-mirror` downloads |
| Bastion | Registries in its own datacenter, **8443** | Pushes; direct, in `NO_PROXY` |
| Bastion | Registry hosts, **22** | Remote install and upgrades of the mirror registry |
| Bastion | Cluster APIs in its datacenter, **6443** | Applying `cluster-resources` with `oc` |
| Every cluster node | Its registry, **8443** | Image pulls through IDMS/ITMS |
| Admin workstations | Bastion, **22** | Operators log in to run the guides |

No two-headed DNS is needed: the bastions resolve internal names, and the proxy resolves Red Hat's.

## Moving the clusters to the new registries

**Short cutover: same registry, new path.** A cluster that stays on an existing registry and only
moves to its new path skips the CA step (it already trusts that registry). It still needs the new
organization's read robot in the pull secret (step 1), the new IDMS/ITMS, CatalogSources and Update
Service (steps 3 to 5), an update (6), and the removal of the old ICSPs (7). The table below is the
full cutover to a new registry host.

Each old registry has a new counterpart (assumed: `mirror-old-lab` → `registry-lab`, `mirror-old-dc1` →
`registry-dc1`, `mirror-old-dc2` → `registry-dc2`; to confirm). Do the lab pair first. Each cluster
moves from its old registry to its new one in a change window, after the
new registry holds the content for the cluster's current version and its next target.

| Order | Change | Node effect |
|---|---|---|
| 1 | Add the new registry's read robot to the global pull secret | None |
| 2 | Add the new registry's CA to the `additionalTrustedCA` ConfigMap (`host..8443` key) | Not in Red Hat's no-drain list; watch it in the lab |
| 3 | Create the new IDMS from the new registry's `cluster-resources` (renamed per run) | None: "If you create an IDMS or ICSP CR object, the MCO does not drain or reboot the node"; IDMS mirrors are digest-only |
| 3b | Create the new ITMS, if the run wrote one | **Drain**: tag mirrors are not `digest-only`, so the no-drain exception does not cover them |
| 4 | Create the new CatalogSources; move Subscriptions to them | None |
| 5 | Point the Update Service at the new registry's release and graph images | None |
| 6 | Run an update with both registries configured | Normal update |
| 7 | Delete its old registry's ICSP/IDMS/ITMS and CatalogSources | **Drain, plan for a reboot**: "If you delete an ITMS, IDMS, or ICSP CR object, the MCO drains and reboots the node" |
| 8 | Remove the old login and CA | None |

Sources: `docs422 modules/images-configuration-registry-mirror.adoc`,
`snippets/node-icsp-no-drain.adoc` ("The node drain does not happen for … the addition of a mirror with the
`pull-from-mirror = "digest-only"` parameter"). Steps 3b and 7 each drain the nodes; plan a window for each. The old registries were filled with oc-mirror v1, so their cluster objects are ICSPs, which oc-mirror v2
replaces with IDMS/ITMS (`modules/oc-mirror-migration-differences.adoc`). List them before the
cutover with `oc get imagecontentsourcepolicy`; step 7 deletes those.

## Checklist

- [ ] All three old registries recorded: mirror registry version (Quay tag), OS, disk, v1 path, which clusters use each, and each cluster's ICSPs (`oc get imagecontentsourcepolicy`; filled by oc-mirror v1)
- [ ] Lab datacenter confirmed; five hostnames agreed and in DNS
- [ ] Five RHEL 9 hosts built and registered; 2 TB backed-up `/data` on each bastion for the cache and archives
- [ ] Internal-CA certificates issued for the three registry FQDNs
- [ ] Firewall: bastions → proxy 443; bastions → registries 8443 and 22; clusters → their registry 8443
- [ ] Proxy allowlist for the bastions approved (release guide, Step 1)
- [ ] Red Hat pull secret (Registry Service Account) in Vault on both bastions
- [ ] Mirror registry 2.0.x installed on the three hosts; `ocp4v2` org, write and read robots created
- [ ] One Vault file per registry on the bastions that push to it
- [ ] Push test passed from each bastion to each of its registries, including any existing registry on its new path (and its v1 path listed in `protected_targets`)
- [ ] Backups scheduled for the registry storage and the bastions' `/data`
- [ ] Lab mirror and lab cluster update done before the production registries are filled

## Still open

- Which datacenter holds the lab, and whether lab clusters exist in both.
- How many clusters each production registry will serve. Red Hat discourages one mirror registry
  for several clusters; if that is our case under the fallback, a highly available registry (Quay,
  [`quay-onprem/`](quay-onprem/README.md)) is the registry product for the mirror approach, not an
  option of its own.
- Whether the bastions may reach Red Hat through the enterprise proxy (security approval, as for the
  current mirror host).
- Each old registry's exact version and OS, and which new registry replaces it (assumed lab → lab,
  DC1 → DC1, DC2 → DC2). An early 1.3 could be upgraded in place, but that is not our plan.
- Red Hat Support: support end of the Quay 3.12 stream that mirror registry 2.0 ships; RHEL 10 plans
  for the mirror registry and `oc-mirror`.

## Diagram sources

The figure is drawn in [`diagrams/prerequisites/source.html`](diagrams/prerequisites/source.html)
and rendered with [diagram-kit](https://github.com/ephico2real2/diagram-kit); the install and render
commands are in [`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md), Diagram sources:

```sh
.venv/bin/diagram-render docs/diagrams/prerequisites/source.html docs/diagrams/prerequisites topology
```

The figure, its text twin and the page change together.
