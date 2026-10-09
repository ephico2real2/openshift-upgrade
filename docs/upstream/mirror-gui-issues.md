# Draft issues for openshift/mirror-gui

Not posted. Read at commit `3cec34f` (2026-10-07). Three separate issues; post only the ones you want.

Issue 3 exposes a credential, so consider sending it to Red Hat's security contact instead of a public issue.

Why these matter for us: [catalog guide, Step 2](../../oc-mirror-ansible/docs/catalog-mirroring-guide.md#optional-plan-the-operator-list-with-mirror-gui).

---

## Issue 1: Make TLS verification configurable; don't disable it by default

**Problem**

Every mirror operation runs oc-mirror with TLS verification turned off for both the source and the
destination, with no setting to change it (`server/index.ts`, around line 1729):

```ts
spawn('oc-mirror', [
  '--v2',
  '--config', configPath,
  '--dest-tls-verify=false',
  '--src-tls-verify=false',
  ...
```

The source is normally `registry.redhat.io`, reached through an enterprise proxy. Without
certificate checks, a man-in-the-middle on that path goes unnoticed. Release signature checks still
apply to release images, but not to every operator or additional image.

**Proposal**

- Default to verifying TLS (drop both flags).
- Add settings (UI and API) to turn verification off per side, with a warning, for lab registries
  with self-signed certificates.
- Allow a custom CA bundle for the destination instead.

---

## Issue 2: Dependency detection misses API dependencies, chosen channels and transitive dependencies

**Problem**

`scripts/catalog_metadata.py` (around lines 378–415) builds `dependencies.json` from:

1. only `olm.package.required` properties; `olm.gvk.required` (a required API) is never read;
2. only the newest bundle of the package's **default** channel;
3. one level: `MirrorConfig.tsx` adds the listed dependencies but does not look up theirs.

An added dependency also gets the package's default channel or a guessed `stable-<x.y>`
(`MirrorConfig.tsx`, around line 880), which may not exist for that package.

Because oc-mirror v2 does not resolve dependencies itself, users may take the auto-added list as
complete and find a missing operator only when the install fails in the disconnected cluster.

**Proposal**

- Read `olm.gvk.required` and map each required API to the package(s) whose bundles provide it
  (`olm.gvk`).
- Compute dependencies for the channel and version range the user selected, not only the default
  channel head.
- Resolve transitively, with a visible "added because of X" chain (the `autoAddedBy` field already
  exists).
- Use the dependency package's real default channel from the catalog data instead of a guess.
- Until then, label the feature as partial in the UI and README.

---

## Issue 3: Published port listens on all interfaces although the API has no authentication

**Problem**

`API.md` says "the API does not require authentication", and `docs/ARCHITECTURE-EVALUATION.md`
assumes a single-user localhost tool. But `local-build.sh` and `mirror-gui.sh` publish the port with
`-p "$WEB_PORT:$CONTAINER_PORT"`, which listens on every host interface. On a shared bastion, anyone
who can reach port 3000 can read the pull secret (`GET /api/pull-secret/content`), replace it
(`POST /api/pull-secret`) and start operations.

**Proposal**

- Publish on `127.0.0.1` by default (`-p "127.0.0.1:$WEB_PORT:$CONTAINER_PORT"`), with an explicit
  option to bind elsewhere.
- Document SSH tunnelling for remote use.
