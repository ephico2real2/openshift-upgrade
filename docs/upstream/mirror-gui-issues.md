# Draft issues for openshift/mirror-gui

Not posted (this session cannot write to openshift/mirror-gui). Post from your account at https://github.com/openshift/mirror-gui/issues/new. Read at commit `3cec34f` (2026-10-07). Three separate issues; post only the ones you want.

Issue 3 exposes a credential, so consider sending it to Red Hat's security contact instead of a public issue.

Fixes for all three, as patches for a fork, are in [`mirror-gui-fork/`](mirror-gui-fork/).

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

**A fix is available:** branch
[`ephico2real2/mirror-gui:fix/tls-deps-bind`](https://github.com/ephico2real2/mirror-gui/tree/fix/tls-deps-bind),
commit `1e1b427` (tests and docs in `8b419ee`). It removes both flags, adds the per-operation opt-out
`skipSourceTlsVerify` (UI switch, off by default, with a warning) and documents it in `API.md`. The
destination is always a local `file://` directory, so only source TLS needs a setting. The new
integration tests fail on `3cec34f`. Happy to open a PR.

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

**A fix is available:** same branch, commit `2773c9c` (E2E tests and `API.md` in `8b419ee`).
`catalog_metadata.py` also writes `dependency-graph.json` (per channel head; required APIs resolved to
the one package providing them; ambiguous or unprovided APIs listed, not guessed). The dependencies API
takes a `channel`, resolves transitively and returns `requiredBy`, the real `defaultChannel` and
`unresolvedApis`; the UI warns about the unresolved ones. Older catalog data falls back to
`dependencies.json`. The new API tests fail on `3cec34f`. Happy to open a PR.

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
