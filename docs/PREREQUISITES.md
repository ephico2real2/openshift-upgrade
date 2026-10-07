# Prerequisites: mirroring bastions and the three registries

| | |
|---|---|
| Date | 2026-10-07 |
| Status | Proposed. No host is built yet; hostnames below are examples |
| Researched | `quay/mirror-registry` (`main` and tags to `v2.0.12`, 2026-08-27); `openshift/openshift-docs` `enterprise-4.18` and `enterprise-4.22`; `quay/quay-docs` `redhat-3.18`; `openshift/oc` and `openshift/oc-mirror` `release-4.22` |
| Needed by | Step 1 ([`oc-mirror-ansible/`](../oc-mirror-ansible/README.md)) and Step 3 ([`quay-onprem/`](quay-onprem/README.md)) to run at all; Step 2 ([`enterprise-proxy/`](enterprise-proxy/README.md)) for the lab registry and the transition. Overview: [`SOLUTIONS.md`](SOLUTIONS.md) |

Before any mirroring run, we need new hosts. **One mirroring bastion in each datacenter**, where every
Ansible and oc-mirror command runs, and **three registries**: one for the lab and one production
registry in each datacenter. They replace the single old registry we mirror into today. This page
says what we run now, what replaces it, and what each host needs before the guides can be followed.

## Summary

| Decision | Recommendation | Why |
|---|---|---|
| Registry software for Step 1 | **mirror registry for Red Hat OpenShift 2.0.x**, a fresh install on each of the three registry hosts | The current Red Hat release; it bundles Quay 3.12 and replaces PostgreSQL with SQLite |
| Old registry | Keep it running until every cluster has moved; then retire it. Do not upgrade it in place | We are moving to new hosts and new names anyway, and only 1.3 → 2.x is a documented upgrade (see below) |
| Content in the new registries | **Mirror again from Red Hat with oc-mirror v2**, pinned versions, lab first | Red Hat documents no way to copy mirror registry data between hosts; a fresh oc-mirror v2 run also writes the IDMS/ITMS and signatures the clusters need |
| Operating system | **RHEL 9** for the bastions and the registry hosts | The mirror registry supports "RHEL 8 and 9"; `oc` and `oc-mirror` 4.22 are built for RHEL 8 and RHEL 9 only. RHEL 10 is not documented for either |
| Bastions | One per datacenter, RHEL 9, reaching Red Hat only through the enterprise proxy | Each bastion fills the registries in its own datacenter; no cross-datacenter pushes |

## What we run today

| Item | Today | Source |
|---|---|---|
| Registry | Red Hat's **mirror registry for Red Hat OpenShift**, the trimmed-down Quay installed with `mirror-registry install`, an old 1.x release (team report) | |
| How it is filled | The manual sync described in [`PROBLEM-STATEMENT.md`](PROBLEM-STATEMENT.md); Step 1 replaces it with oc-mirror v2 and Ansible | |
| Hosts | One registry host; the exact 1.x version, OS and disk are to be recorded with the commands below | |

Record the old registry's facts before anything changes. On the registry host:

```bash
podman ps --format '{{.Names}}  {{.Image}}'        # quay-app, quay-redis, quay-postgres (1.x) and their image tags
podman images | grep -E 'quay|postgres|redis|pause'
cat /etc/redhat-release
df -h; podman volume ls                              # quay-storage, pg-storage (1.3+) or /etc/quay-install (older)
systemctl list-units 'quay-*'
```

The Quay image tag gives the release: Quay 3.6 is mirror registry 1.0–1.1, 3.7 is 1.2, 3.8 is 1.3, and
3.12 is 2.0 (from the `.env` image pins of each `quay/mirror-registry` tag).

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
- **Our decision: a new setup.** It is the simpler path for us whichever 1.x we run:
  - the new registries are on new RHEL 9 hosts with new names, three of them instead of one;
  - their content is mirrored fresh by oc-mirror v2, which also writes the IDMS, ITMS, signature
    ConfigMap and Update Service files the clusters need;
  - the old registry keeps serving the clusters, untouched, until each one has switched.
- If someone proposes upgrading the old host instead: only from 1.3, with a backup first, and it
  still leaves one registry on the old host.

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
  <img alt="Target layout. In datacenter 1 a mirroring bastion reaches Red Hat only through the enterprise proxy and pushes over TCP 8443 to two mirror registries: the lab registry and the datacenter 1 production registry. In datacenter 2 its own bastion does the same for the datacenter 2 production registry. Lab clusters pull from the lab registry and each datacenter's production clusters pull from their own registry. The old 1.x registry keeps serving until every cluster has switched, then it is retired. All hosts run RHEL 9." src="diagrams/prerequisites/topology.light.png">
</picture>

*Proposed: none of these hosts exists yet. Each bastion pushes only to registries in its own
datacenter. The old registry stays until the last cluster has switched.*

```text
             DATACENTER 1                                    DATACENTER 2
BASTION      mirror-bastion-dc1 (RHEL 9)                     mirror-bastion-dc2 (RHEL 9)
             Ansible + oc-mirror v2 + Vault                  Ansible + oc-mirror v2 + Vault
               | 443 via the enterprise proxy -> Red Hat       | 443 via the enterprise proxy -> Red Hat
               | 8443 direct                                   | 8443 direct
REGISTRIES   registry-lab   registry-dc1                     registry-dc2
             (mirror registry 2.0.x on RHEL 9, one host each)
CLUSTERS     lab clusters   production clusters, DC1         production clusters, DC2
OLD          the 1.x registry, serving until every cluster has switched, then retired
```

| Host (example name) | Datacenter | Role | Fills / serves |
|---|---|---|---|
| `mirror-bastion-dc1.example.com` | DC1 | Mirroring bastion: all Ansible, `oc-mirror`, `oc` and `skopeo` commands | Pushes to `registry-lab` and `registry-dc1` |
| `mirror-bastion-dc2.example.com` | DC2 | Mirroring bastion | Pushes to `registry-dc2` |
| `registry-lab.example.com:8443` | DC1 (to confirm) | Lab registry; new content lands here first | Lab clusters |
| `registry-dc1.example.com:8443` | DC1 | Production registry | Production clusters in DC1 |
| `registry-dc2.example.com:8443` | DC2 | Production registry | Production clusters in DC2 |

**Which datacenter holds the lab** is to confirm; the table assumes DC1. If the lab is elsewhere,
the bastion of that datacenter fills it.

### Order of a mirroring cycle

1. Dry-run on the DC1 bastion; size and agree the pinned versions (release guide, "Mirroring an
   upgrade path").
2. Mirror into **`registry-lab`** and update a lab cluster with that content.
3. With the **same pinned versions and ImageSets**, mirror into **`registry-dc1`** (DC1 bastion) and
   **`registry-dc2`** (DC2 bastion).
4. Production clusters in each datacenter use their own registry's `cluster-resources`.

Each run is a mirror-to-mirror run straight from Red Hat, with **its own workspace per registry** (e.g. `/data/oc-mirror/workspace-dc1-run-a`): Red Hat ties incremental updates to the same image set configuration and destination registry (`modules/oc-mirror-updating-registry-about.adoc`). Release images are pinned by digest, so
the three registries hold the same release content. Operator catalogs are rebuilt by each run from
the catalog image of the day; for byte-identical catalogs across the three, mirror on the same day,
or move to oc-mirror's mirror-to-disk / disk-to-mirror workflow (one archive, pushed three times),
which the playbooks do not do yet.

**Mirror-to-mirror has no cache.** Red Hat: the mirror-to-mirror workflow "does not use a cache,
restarts from the beginning after a failure, and requires no additional disk space"
(`modules/oc-mirror-workflows-table.adoc`). A rerun after a failure starts over; image layers
already in the registry are not uploaded again (our reading of how `containers/image` checks the
destination, not a Red Hat statement).

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
| Disk | `/data` volume, 500 GB to start, on backed-up storage | Mirror-to-mirror needs little: workspace, logs, `cluster-resources`. Size it to 1 TB or more if the team adopts mirror-to-disk ("requires additional disk space"); Red Hat says to put cache and workspace "on reliable and backed-up storage" |
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

1. Create the organization **`ocp4`** (the playbooks' `target_registry_path`).
2. Create a robot account with **write** to `ocp4` for the bastion, e.g. `ocp4+mirror`.
3. Create a robot account with **read** for the clusters' pull secret, e.g. `ocp4+pull`.
4. Run the push test in the release guide, Step 5.

### One Vault file per registry

The playbooks read `vars/credentials.yml`. For three registries, keep one encrypted file each and
pass it with `-e @`; extra variables win over `vars_files`:

```bash
ansible-vault create vars/registry-dc1.yml
#   target_registry_fqdn: "registry-dc1.example.com:8443"
#   target_registry_user: "ocp4+mirror"
#   target_registry_password: "<robot token>"

ansible-playbook playbook.yml --ask-vault-pass -e @vars/registry-dc1.yml \
  -e workspace_path=/data/oc-mirror/workspace-dc1 -e oc_mirror_dry_run=true
```

Keep `vars/credentials.yml` as the lab registry's file. Add `vars/registry-*.yml` to `.gitignore`
before creating them.

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

Each cluster moves from the old registry to its datacenter's new one in a change window, after the
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
| 7 | Delete the old registry's ICSP/IDMS/ITMS and CatalogSources | **Drain, plan for a reboot**: "If you delete an ITMS, IDMS, or ICSP CR object, the MCO drains and reboots the node" |
| 8 | Remove the old login and CA | None |

Sources: `docs422 modules/images-configuration-registry-mirror.adoc`,
`snippets/node-icsp-no-drain.adoc` ("The node drain does not happen for … the addition of a mirror with the
`pull-from-mirror = "digest-only"` parameter"). Steps 3b and 7 each drain the nodes; plan a window for each. If the old registry was filled with oc-mirror v1 or
`oc adm release mirror`, its cluster objects are ICSPs, which oc-mirror v2 replaces with IDMS/ITMS
(`modules/oc-mirror-migration-differences.adoc`).

## Checklist

- [ ] Old registry recorded: mirror registry version (Quay tag), OS, disk, which clusters use it
- [ ] Lab datacenter confirmed; five hostnames agreed and in DNS
- [ ] Five RHEL 9 hosts built and registered; `/data` volumes attached
- [ ] Internal-CA certificates issued for the three registry FQDNs
- [ ] Firewall: bastions → proxy 443; bastions → registries 8443 and 22; clusters → their registry 8443
- [ ] Proxy allowlist for the bastions approved (release guide, Step 1)
- [ ] Red Hat pull secret (Registry Service Account) in Vault on both bastions
- [ ] Mirror registry 2.0.x installed on the three hosts; `ocp4` org, write and read robots created
- [ ] One Vault file per registry on the bastions that push to it
- [ ] Push test passed from each bastion to each of its registries
- [ ] Backups scheduled for the registry storage and the bastions' `/data`
- [ ] Lab mirror and lab cluster update done before the production registries are filled

## Still open

- Which datacenter holds the lab, and whether lab clusters exist in both.
- How many clusters each production registry will serve. Red Hat discourages one mirror registry
  for several clusters; if that is our case, Step 3 (full Quay) is the long-term answer.
- Whether the bastions may reach Red Hat through the enterprise proxy (security approval, as for the
  current mirror host).
- The old registry's exact version; if it is 1.3, an in-place upgrade remains possible but is not
  our plan.
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
