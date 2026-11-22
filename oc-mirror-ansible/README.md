# oc-mirror v2 with Ansible

Mirrors OpenShift release images and operator catalogs into an internal registry for a
disconnected cluster, using oc-mirror v2 and Ansible. The Red Hat pull secret and registry
login come from Ansible Vault. The proxy comes from the mirror host.

Before the first run, build the hosts in [`docs/PREREQUISITES.md`](../docs/PREREQUISITES.md): one
mirroring bastion per datacenter (RHEL 9), where these playbooks run, and the lab and two
production mirror registries they push to.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/prerequisites/topology.dark.png">
  <source srcset="../docs/diagrams/prerequisites/topology.light.png">
  <img alt="Target layout. In datacenter 1 a mirroring bastion reaches Red Hat only through the enterprise proxy and pushes over TCP 8443 to two mirror registries: the lab registry and the datacenter 1 production registry. In datacenter 2 its own bastion does the same for the datacenter 2 production registry. Lab clusters pull from the lab registry and each datacenter's production clusters pull from their own registry. Three old 1.x mirror registries, one per role, keep serving until their clusters have switched, then they are retired; meanwhile each datacenter's bastion may also push the same content into them on a new path, never into the oc-mirror v1 path. All new hosts run RHEL 9." src="../docs/diagrams/prerequisites/topology.light.png">
</picture>

*Where the playbooks run (the bastions) and where they push (the registries); proposed, not built yet.*

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/mirroring/run-flow.dark.png">
  <source srcset="docs/diagrams/mirroring/run-flow.light.png">
  <img alt="One Step 1 release run. On the mirroring bastion: start the playbook in tmux with the Vault password; it checks the Red Hat pull secret, writes a private auth file and renders the ImageSet. A dry-run lists what would be copied; anything in missing.txt is fixed first. The real run downloads into an archive on the bastion and then pushes that archive into the lab registry, later the production registry; it retries each image five times, then the whole run up to three more times two minutes apart, and the cache lets a rerun resume. The auth file is removed even when the run fails. Then verify the tags, the .sig tags and the cluster-resources folder. In the cluster's change window an admin trusts the registry CA, applies the renamed IDMS and ITMS, the signatures and CatalogSources, sets up the Update Service, and oc adm upgrade lists the target." src="docs/diagrams/mirroring/run-flow.light.png">
</picture>

*One run end to end: download once, push to lab, then production. Red boxes are what stops a run and what fixes it.*

| Guide | Covers |
| --- | --- |
| [docs/release-mirroring-guide.md](docs/release-mirroring-guide.md) | Host setup, proxy, Ansible Vault, release mirroring (4.18.17, EUS), OpenShift Update Service, upgrade path 4.18 → 4.20 → 4.22 |
| [docs/catalog-mirroring-guide.md](docs/catalog-mirroring-guide.md) | Operator catalogs (`v$OCP_VERSION`), inventory, package filtering, CatalogSources, catalogs across the upgrade path |

## Files

| File | Purpose |
| --- | --- |
| `playbook.yml` | Release images (+ update graph and Update Service operator) |
| `catalogs-playbook.yml` | Operator catalogs, one group and version per run |
| `templates/imageset-config.yaml.j2` | Release ImageSet |
| `templates/catalogs-imageset.yaml.j2` | Catalog ImageSet |
| `vars/catalogs-redhat.yml`, `vars/catalogs-partner.yml` | **Samples only** (IBM Fusion's sample setup). Replace them with your operator inventory |
| `docs/diagrams/mirroring/` | Source page and light/dark PNGs for the guides' figures: a run end to end, the proxy routes, the two upgrade-path runs |
| `vars/registry.yml.example` | One Vault file per registry and path you push to: a new mirror registry, or an existing registry on a new path (with `protected_targets`) |
| `vars/credentials.yml.example` | Shape of the registry login. Create the real file with `ansible-vault create` |
| `vars/env.yml.example` | Values of one environment, no secrets: `base_path`, `oc_mirror_bin`, `target_registry_fqdn`, `mirror_namespace`. Pass a copy to every run with `-e @vars/env-<name>.yml` |
| `vars/env-lab.yml` | The environment file of the Hetzner lab ([`scripts/host-prep/INSTALL.md`](../scripts/host-prep/INSTALL.md), step 14) |
| [`docs/cluster-inventory.md`](docs/cluster-inventory.md) | Cheat sheet: read-only `oc` commands that list a cluster's version, mirrors, organizations, catalogs and operators, and where each result goes in the vars files |

Not in Git (see `.gitignore`): `vars/credentials.yml`, `vars/registry-*.yml`, `vars/redhat-pull-secret.json`, the
`oc-mirror` binary. Create them on the mirror host as the release guide describes.

## Quick start

```bash
# Release images, dry-run first
ansible-playbook playbook.yml --ask-vault-pass -e oc_mirror_dry_run=true

# Red Hat operator catalog for 4.18, dry-run first
ansible-playbook catalogs-playbook.yml --ask-vault-pass \
  -e catalog_ocp_version=4.18 -e @vars/catalogs-redhat.yml -e oc_mirror_dry_run=true
```

Tested with stand-in `oc-mirror` and Vault files (rendering, retries, dry-run, auth-file
cleanup). On 2026-11-22, also tested with `-e @vars/env-lab.yml` and without it, in a Rocky Linux 9 container.
Not yet run against real registries.
