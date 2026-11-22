# Install a mirror registry host

This procedure prepares a RHEL 9 family host and installs the mirror registry for Red Hat OpenShift on it. You run
three scripts in order. Each step shows the commands and the output that you must see before you continue.

The examples use the test server of 2026-11-22: Rocky Linux 9.9 at Hetzner, with the name
`kcs-ewd-registry.getsolisvault.com`. For another host, change the two variables in step 1.

| Step | Where | What it does |
|---|---|---|
| 1 | Your workstation | Sets the host variables |
| 2 | Your workstation | Copies the scripts and the Red Hat tarballs to the host |
| 3 | Host | Installs Podman with `install-podman.sh` |
| 4 | Host | Installs `tmux`, `oc`, `kubectl` and `oc-mirror` with `install-cli-tools.sh` |
| 5 | Host | Starts a `tmux` session |
| 6 | Host | Does a dry run of `install-mirror-registry.sh` |
| 7 | Host | Installs the mirror registry |
| 8 | Host and workstation | Makes sure that the registry works |

The details of each script are in [`README.md`](README.md).

## Before you start

- You have SSH access as root to the host, with a key.
- The `tools/` folder at the root of this repository holds the three Red Hat tarballs:
  `openshift-client-linux-amd64-rhel9.tar.gz`, `oc-mirror-rhel9-linux-amd64.tar.gz` and
  `mirror-registry-amd64.tar.gz`. Git ignores this folder.
- The registry name has a DNS record that points to the host. In Cloudflare, the record must be "DNS only", not
  "Proxied". A proxied record hides the host address, and the dry run in step 6 then fails.
- Port 8443 of the host is open to the registry clients.

To make sure that the DNS record is correct, run this command on your workstation:

```bash
dig +short kcs-ewd-registry.getsolisvault.com
```

The output must be the address of the host, `138.201.254.103` for the test server. A Cloudflare address, for
example `104.21.93.198`, means that the record is still proxied.

## 1. Set the host variables

On your workstation, go to the root of this repository and set two variables:

```bash
cd ~/gitRepos/openshift-upgrade
REGISTRY_HOST=kcs-ewd-registry.getsolisvault.com
SSH_TARGET=root@$REGISTRY_HOST
```

`REGISTRY_HOST` is the registry name. `SSH_TARGET` is the SSH login for the host.

## 2. Copy the scripts and the tarballs to the host

```bash
scp scripts/host-prep/install-podman.sh \
    scripts/host-prep/install-cli-tools.sh \
    scripts/host-prep/install-mirror-registry.sh \
    "$SSH_TARGET":/root/
rsync -a --partial --info=progress2 --chown=root:root \
    --exclude .DS_Store --exclude pull-secret.txt \
    tools/ "$SSH_TARGET":/root/tools/
```

The `rsync` command does not copy the pull secret, because these steps do not need it. `--chown=root:root` sets the
owner on the host. Without it, the files keep the user ID of your workstation. If `rsync` is missing on the host,
first run `ssh "$SSH_TARGET" dnf install -y rsync`.

Make sure that the tarballs arrived complete:

```bash
shasum -a 256 tools/*.tar.gz
ssh "$SSH_TARGET" 'sha256sum /root/tools/*.tar.gz'
```

The hashes on both sides must be the same.

## 3. Install Podman

Log in to the host. Do the remaining steps on the host, as root:

```bash
ssh "$SSH_TARGET"
bash /root/install-podman.sh
```

The last lines must be similar to these:

```text
[install-podman] installed: podman-5.8.5-3.el9_9.x86_64
[install-podman] wrote: /etc/containers/containers.conf.d/50-rootless-network.conf (default_rootless_network_cmd = "slirp4netns")
[install-podman] done: podman version 5.8.5
```

If you run the script again, it shows `unchanged:` for the setting file. That is correct.

## 4. Install tmux and the OpenShift CLI tools

```bash
bash /root/install-cli-tools.sh
```

The last lines must be similar to these:

```text
[install-cli-tools] tmux:      tmux 3.2a
[install-cli-tools] oc:        Client Version: 5.0.1
[install-cli-tools] kubectl:   Client Version: v1.36.2
[install-cli-tools] oc-mirror: 2.0.0-202610201601.p2.gc4d52fa.assembly.stream.el9-c4d52fa
[install-cli-tools] oc-mirror supports OpenShift: [4.12,4.14,4.16,4.18,4.20,4.21,4.22,4.23,5.0]
[install-cli-tools] done
```

If the line `note: /usr/local/bin is not in PATH` appears, log out and log in again.

## 5. Start a tmux session

The mirror registry install takes several minutes. If your SSH connection drops, a job in `tmux` continues. Start
the session:

```bash
tmux new -s registry
```

If the connection drops, log in again and run `tmux attach -t registry`.

## 6. Do a dry run of the mirror registry install

In the `tmux` session, set the registry name and do the dry run:

```bash
export QUAY_HOSTNAME=kcs-ewd-registry.getsolisvault.com
bash /root/install-mirror-registry.sh --dry-run
```

The dry run changes nothing. The last lines must be similar to these:

```text
[install-mirror-registry] name: kcs-ewd-registry.getsolisvault.com resolves to this host (138.201.254.103 2a01:4f8:173:256f::2 )
[install-mirror-registry] command (in /registry-data/mirror-registry): ./mirror-registry install --quayHostname kcs-ewd-registry.getsolisvault.com:8443 --quayRoot /registry-data/quay-install --quayStorage /registry-data/quay-storage --sqliteStorage /registry-data/sqlite-storage --initUser init -v
[install-mirror-registry] dry run: all checks passed; nothing was changed
```

If the dry run shows `ERROR:`, fix the cause that the message names, and do the dry run again. Do not continue to
step 7 before the dry run passes.

To use your own TLS certificate, also set `SSL_CERT` and `SSL_KEY` to the certificate file and the key file. If you do
not set them, the installer makes its own certificate, and each client must then trust its CA. To set the password of
the `init` user, set `INIT_PASSWORD`. If you do not set it, the installer makes a random password.

## 7. Install the mirror registry

In the same `tmux` session, run the script without `--dry-run`:

```bash
bash /root/install-mirror-registry.sh
```

The script unpacks the installer, runs `./mirror-registry install`, and writes the full output to
`/registry-data/install-<time>.log`. The last lines must be similar to these:

```text
[install-mirror-registry] installed. The credentials of init are in the last lines of /registry-data/install-<time>.log
[install-mirror-registry] health: https://kcs-ewd-registry.getsolisvault.com:8443/health/instance returned HTTP 200
[install-mirror-registry] log in with: podman login kcs-ewd-registry.getsolisvault.com:8443
```

Read the password of the `init` user from the log:

```bash
tail -5 /registry-data/install-*.log
```

Keep the password in a password manager. The log has mode `0600`, so only root can read it.

If the install fails, the script shows `ERROR: mirror-registry install failed; read /registry-data/install-<time>.log`.
Read the last lines of that log before you try again.

## 8. Make sure that the registry works

On the host, look at the registry services and the data folders:

```bash
systemctl list-units 'quay*' --no-pager
podman pod ps
du -sh /registry-data/*
```

The `quay` units must be `active`, and the pod must be `Running`.

On your workstation, log in to the registry with the `init` user:

```bash
podman login "$REGISTRY_HOST:8443"
```

If the installer made the certificate, `podman login` refuses it because the CA is not trusted. To trust the CA, copy
`/registry-data/quay-install/quay-rootCA/rootCA.pem` from the host to the trust store of the client. For a one-time
test, you can add `--tls-verify=false` to `podman login` instead. Do not use that option for real work.

## Status of this procedure

| Step | Tested on the test server |
|---|---|
| 1 and 2 | Yes. The hashes matched after the copy |
| 3 | Yes, with a second run and a test as a rootless user |
| 4 | Yes, before `tmux` was added to the script. The `tmux` step did not run yet |
| 5 | Not yet |
| 6 | Yes. All checks passed with the real name |
| 7 and 8 | Not yet. Record the results here after the first install |

The path `quay-install/quay-rootCA/rootCA.pem` in step 8 is the place where mirror registry 1.x kept its CA. After the first
install, make sure that 2.0.13 uses the same path. If it does not, correct this step.
