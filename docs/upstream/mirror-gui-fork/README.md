# mirror-gui fixes (fork) and a Stream 9 test VM

Fixes for the three issues drafted in [`../mirror-gui-issues.md`](../mirror-gui-issues.md), made on
branch `fix/tls-deps-bind` on top of upstream `openshift/mirror-gui` commit `3cec34f`. The commits are
kept here as [`patches/`](patches/) until the fork `ephico2real2/mirror-gui` exists.

| Patch | Issue | Change |
|---|---|---|
| `0001` | 1, TLS | No more hardcoded `--src-tls-verify=false --dest-tls-verify=false`. Source TLS is verified unless the per-run option `skipSourceTlsVerify` (UI switch with a warning) is on. The destination is always `file://`, so there is no destination TLS to set |
| `0002`, `0004` | 3, open port | `local-build.sh` and `mirror-gui.sh` publish on `WEB_BIND_ADDRESS`, default `127.0.0.1`; any other address prints a warning. README and `--help` document it and SSH tunnelling |
| `0003` | 2, dependencies | `catalog_metadata.py` writes `dependency-graph.json`: per channel head, package dependencies plus required APIs resolved to the one package providing them; ambiguous or unprovided APIs are listed, not guessed. The API follows dependencies of dependencies for the chosen channel; the UI re-checks when the channel changes, uses real default channels and warns about unresolved APIs |

## What was tested, and where

In the Claude Code cloud container (Ubuntu, Node 22, as root), on 2026-10-09:

- **Unit and integration tests (vitest):** 156 of 157 pass. The one failure,
  `pathAvailability > returns false when nearest existing ancestor is not writable`, fails the same way
  on upstream: it needs a non-root user.
- **New tests fail on the old code:** 3 TLS tests and 5 dependency API tests fail on upstream and pass
  with the patches.
- **Browser tests (Playwright, as CI):** 110 of 110 with one worker, as CI runs them. With 3 workers,
  one or two bulk-delete row tests failed, different ones on each run.
- **Lint and type check:** ESLint is clean; `tsc` has no new errors (the server's one type error at
  the registry-auth handler is upstream's).
- **ShellCheck:** no new findings in the changed scripts.
- **Port binding:** the real `local-build.sh --run` and `mirror-gui.sh` run against a stand-in `podman`
  that records its arguments: `-p 127.0.0.1:3000:3001` by default, `-p 0.0.0.0:3000:3001` plus a
  warning only with `WEB_BIND_ADDRESS=0.0.0.0`.

**Not tested: the container on CentOS Stream 9.** The cloud environment's network policy blocks
`cloud.centos.org` (the Stream 9 VM image), `quay.io` (the Stream 9 container image) and
`registry.access.redhat.com` (mirror-gui's UBI base images), and it has no KVM. Run the VM below on
your machine.

## The Stream 9 VM

[`stream9.yaml`](stream9.yaml) is a Lima template: CentOS Stream 9, 4 CPUs, 8 GiB, Podman, Node 22,
ShellCheck. It mounts this repo read-only and does not forward port 3000, so the loopback-only binding
can be checked from inside.

```bash
limactl start --name=mirror-gui-stream9 docs/upstream/mirror-gui-fork/stream9.yaml
limactl shell mirror-gui-stream9 ~/openshift-upgrade/docs/upstream/mirror-gui-fork/verify.sh
```

[`verify.sh`](verify.sh) clones the fork branch (or applies the patches to upstream when the fork
doesn't exist yet), then runs the tests and ShellCheck. With your Red Hat pull secret at
`~/pull-secret.json` inside the VM, it also builds and starts the container and checks:

- **Port binding:** port 3000 listens on `127.0.0.1` only and can't be reached on the VM's own address.
- **TLS:** a real mirror run's oc-mirror command line has no `tls-verify=false`.

To use the UI from your machine:
`ssh -F ~/.lima/mirror-gui-stream9/ssh.config -L 3000:127.0.0.1:3000 lima-mirror-gui-stream9`.

The template and script were checked for syntax (YAML, `bash -n`, ShellCheck), and the patch path of
`verify.sh` ran in the cloud container. Booting the VM has not been tried.
