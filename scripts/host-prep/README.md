# Host preparation scripts

Scripts that prepare a RHEL 9 family host (RHEL, Rocky Linux, AlmaLinux) to be a mirror registry host or a mirroring
bastion. See [`docs/PREREQUISITES.md`](../../docs/PREREQUISITES.md) for what each host needs.

| Script | What it does |
|---|---|
| [`install-podman.sh`](install-podman.sh) | Installs Podman and sets the rootless network command, per Red Hat "Configure rootless Podman networking" |
| [`install-cli-tools.sh`](install-cli-tools.sh) | Installs `tmux` with `dnf`, and `oc`, `kubectl` and `oc-mirror` from the Red Hat tarballs in a tools folder |
| [`install-mirror-registry.sh`](install-mirror-registry.sh) | Installs the mirror registry for Red Hat OpenShift, with all its data in one folder |

Run them in the order of this table. [`INSTALL.md`](INSTALL.md) gives the full procedure. It has the commands and
the expected output of each step, from the copy to the host to a working registry.

## install-podman.sh

From RHEL 9.5 (Podman 5), rootless Podman uses `pasta` for its network. Rootless means that a user other than root
runs the containers. On a host without a default route, `pasta` fails with this error:

```text
Error: pasta failed with exit code 1:
External interface not usable
```

Red Hat's fix sets the rootless network command back to `slirp4netns`. This script does the fix in four steps:

1. It installs `podman`, `slirp4netns`, `passt` (which provides `pasta`) and `container-selinux` with `dnf`.
2. It writes `/etc/containers/containers.conf.d/50-rootless-network.conf` with this content:

   ```toml
   [network]
   default_rootless_network_cmd = "slirp4netns"
   ```

3. For each user that you name with `--user`, it runs `podman system migrate` as that user.
4. It reads the setting back with `podman info` as each named user. If the value is wrong, it stops with an error.

### Usage

Run the script as root. Copy it to the host first:

```bash
scp scripts/host-prep/install-podman.sh root@<host>:/root/
ssh root@<host> 'bash /root/install-podman.sh --help'
```

| Command | Result |
|---|---|
| `bash install-podman.sh` | Installs the packages and writes the setting for all users |
| `bash install-podman.sh --user quay` | Also migrates and checks the user `quay` |
| `bash install-podman.sh --user quay --test` | Also runs a container as `quay` that makes an HTTPS request |
| `bash install-podman.sh --network-cmd pasta` | Sets the Podman 5 default again |

You can run the script again. If the setting file has the same content, the script does not write it. If the content
changes, the script first keeps a copy of the old file as `50-rootless-network.conf.bak.<time>`.

`podman system migrate` stops all running containers of the user. If a named user has running containers, the script
stops with an error. To let it stop them, add `--stop-containers`.

### What the script checks

| Check | Error message |
|---|---|
| The script runs as root | `run as root` |
| The host is RHEL 9 family | `RHEL 9 family only; this host is ...` |
| Each `--user` exists, is not root, and has entries in `/etc/subuid` and `/etc/subgid` | The missing item, with the `usermod` command to fix it |
| The effective setting for each `--user` is the requested value | The effective value, and the user file that can override it |
| With `--test`, the container gets an HTTP reply | The URL and the status that `curl` returned |

The test proves the network path only. Any HTTP status passes, because it shows that a reply came back. Without a
network, `curl` exits with code 6 and status `000`.

### Test record

The script ran on 2026-11-22 on a Hetzner server with Rocky Linux 9.9, kernel `5.14.0-687.54.1.el9_8.x86_64`.

| Test | Result |
|---|---|
| First run as root, no `--user` | Installed `podman-5.8.5-3.el9_9`, `slirp4netns-1.3.4-1.el9`, `passt-0^20260728.gf8df3f1-1.el9`, `container-selinux-2.250.0-1.el9`. Wrote the setting file |
| Run again | `unchanged: /etc/containers/containers.conf.d/50-rootless-network.conf` |
| `--user podtest --test`, with a temporary user | `effective rootless network command: slirp4netns`, then `test passed: HTTP 404 from https://registry.access.redhat.com/ through slirp4netns` |
| The same container with `--network=none` | `curl: (6) Could not resolve host`, status `000`, exit code 6 |
| `--network-cmd foo` | `ERROR: --network-cmd must be slirp4netns or pasta, not 'foo'` |
| `shellcheck` | No findings |

The test user was removed after the test. That server has a default route, so `pasta` also worked there. The setting
matters on hosts without a default route.

### Notes

- The Red Hat text names the user file `~/.config/containers/container.conf`. Podman reads
  `~/.config/containers/containers.conf`, with an "s", as `man containers.conf` on the host shows. A value in that
  user file overrides the file that this script writes.
- Podman 5.0 deprecated `slirp4netns`, and Podman 6 removes it. This fix applies to the RHEL 9 line only. The
  script stops on other major versions.
- Without a systemd session for the user, Podman logs `Falling back to --cgroup-manager=cgroupfs`. This warning is
  normal for `runuser`. For a user that runs containers as services, enable a session at boot with
  `loginctl enable-linger <user>`.
- Root (rootful Podman) does not use this setting. If the mirror registry runs as root, its network does not change.

### Sources

- Red Hat OpenShift documentation, disconnected environments, "4.3. Configure rootless Podman networking"
- `man containers.conf` on the host, from `containers-common-5.8-2.el9`
- [Podman 6 high-level design (pasta default since 5.0, slirp4netns removed in 6)](https://sources.debian.org/src/podman/5.7.0%2Bds2-3/contrib/design-docs/podman6hld.md)
- [Fedora change proposal: Podman 6](https://fedoraproject.org/wiki/Changes/Podman6)

## install-cli-tools.sh

This script installs `tmux` with `dnf`. Then it installs `oc` and `kubectl` from the OpenShift client tarball, and
`oc-mirror` from its own tarball, into `/usr/local/bin`. If the SSH connection drops, a long job in `tmux`
continues. It does not install the mirror registry. That tarball is installed in a separate
step.

### Variables

Each path is a variable with a default. To change a path, set the variable before the command.

| Variable | Default | What it is |
|---|---|---|
| `TOOLS_DIR` | `/root/tools` | The folder with the tarballs |
| `BIN_DIR` | `/usr/local/bin` | The folder for the installed commands |
| `OC_TARBALL` | `$TOOLS_DIR/openshift-client-linux-amd64-rhel9.tar.gz` | Holds `oc` and `kubectl` |
| `OC_MIRROR_TARBALL` | `$TOOLS_DIR/oc-mirror-rhel9-linux-amd64.tar.gz` | Holds `oc-mirror` |

### Usage

Copy the tarballs from `tools/` in this repository to the host. The folder is in `.gitignore`. Then run the script as
root:

```bash
rsync -a --chown=root:root --exclude .DS_Store tools/ root@<host>:/root/tools/
scp scripts/host-prep/install-cli-tools.sh root@<host>:/root/
ssh root@<host> 'bash /root/install-cli-tools.sh'
```

The `--chown` option sets the owner to root. Without it, `rsync -a` keeps the user ID of your Mac.

To use other paths, set the variables:

```bash
TOOLS_DIR=/data/tools BIN_DIR=/opt/bin bash /root/install-cli-tools.sh
```

The script does these checks before it installs a file:

- It runs as root, on a RHEL 9 family host, on `x86_64`.
- Each tarball exists and holds the expected files. The script prints the SHA-256 hash of each tarball.

When it finishes, it prints the version of each command. You can run it again. If a command already has the same
content, `install -C` does not replace it.

### The same steps as commands

To install by hand, run these commands as root. They do the same steps as the script.

```bash
dnf install -y tmux

TOOLS_DIR=/root/tools
BIN_DIR=/usr/local/bin
OC_TARBALL=$TOOLS_DIR/openshift-client-linux-amd64-rhel9.tar.gz
OC_MIRROR_TARBALL=$TOOLS_DIR/oc-mirror-rhel9-linux-amd64.tar.gz

WORK_DIR=$(mktemp -d)
tar -xzf "$OC_TARBALL" -C "$WORK_DIR" oc kubectl
tar -xzf "$OC_MIRROR_TARBALL" -C "$WORK_DIR" oc-mirror
install -C -m 0755 "$WORK_DIR"/oc "$WORK_DIR"/kubectl "$WORK_DIR"/oc-mirror "$BIN_DIR"/
rm -rf "$WORK_DIR"

tmux -V
oc version --client
kubectl version --client
oc-mirror version --output=json 2>/dev/null
```

### Test record

The script ran on 2026-11-22 on the same Rocky Linux 9.9 server.

| Test | Result |
|---|---|
| First run | Installed `/usr/local/bin/oc`, `kubectl` and `oc-mirror`. The `tmux` step was added later and did not run in this test |
| Versions | `oc` Client Version 5.0.1, `kubectl` v1.36.2, `oc-mirror` 2.0.0 (build of 2026-10-20) |
| `oc-mirror` support | OpenShift 4.12, 4.14, 4.16, 4.18, 4.20, 4.21, 4.22, 4.23 and 5.0 |
| Run again | Exit code 0. The modification time of `oc` did not change |
| `OC_TARBALL=/nope.tar.gz` | `ERROR: tarball not found: /nope.tar.gz` |
| `BIN_DIR=/root/clitest` | Installed the three commands there, and printed `note: /root/clitest is not in PATH` |
| `ldd` on the three commands | No missing library |
| `shellcheck` | No findings |

| Tarball | SHA-256 |
|---|---|
| `openshift-client-linux-amd64-rhel9.tar.gz` | `13df492a60126d3274d8f48743d441e927b0e3b28de63cb5ba09e7db052cd356` |
| `oc-mirror-rhel9-linux-amd64.tar.gz` | `fd2b899c137bc9181e986945c080439cfe2d8034d3ef97d980386020d3896d72` |

`oc-mirror` prints a greeting on stderr and its version as JSON on stdout. The script reads the JSON.

## install-mirror-registry.sh

This script installs the mirror registry for Red Hat OpenShift (a small Quay registry) on the host where it runs. It
puts all registry data in one folder, `/registry-data` by default.

### Where the mirror registry keeps its data

Version 2.0.13 keeps data in three places. `--quayRoot` alone does not move all of it.

| Flag | What it holds | Default of the installer | Default of this script |
|---|---|---|---|
| `--quayRoot` | Configuration, certificates, installer files | `~/quay-install` | `/registry-data/quay-install` |
| `--quayStorage` | The image blobs, which is almost all the data | Podman volume `quay-storage` | `/registry-data/quay-storage` |
| `--sqliteStorage` | The SQLite database | Podman volume `sqlite-storage` | `/registry-data/sqlite-storage` |

The Podman volumes are in `/var/lib/containers/storage/volumes/`. With all three in one folder, a backup or a move to
another disk has one source.

### Variables

| Variable | Default | What it is |
|---|---|---|
| `QUAY_HOSTNAME` | none, required | The registry FQDN, without a port. It must resolve to this host |
| `QUAY_PORT` | `8443` | The registry port |
| `REGISTRY_DATA` | `/registry-data` | The parent folder of all paths below |
| `TOOLS_DIR` | `/root/tools` | The folder with the tarball |
| `MIRROR_REGISTRY_TARBALL` | `$TOOLS_DIR/mirror-registry-amd64.tar.gz` | The Red Hat tarball |
| `MIRROR_REGISTRY_DIR` | `$REGISTRY_DATA/mirror-registry` | The unpacked installer, 2.8 GB |
| `QUAY_ROOT` | `$REGISTRY_DATA/quay-install` | `--quayRoot` |
| `QUAY_STORAGE` | `$REGISTRY_DATA/quay-storage` | `--quayStorage` |
| `SQLITE_STORAGE` | `$REGISTRY_DATA/sqlite-storage` | `--sqliteStorage` |
| `INIT_USER` | `init` | The first registry user |
| `INIT_PASSWORD` | empty | If empty, the installer makes a random password |
| `SSL_CERT`, `SSL_KEY` | empty | If empty, the installer makes a certificate. Set both or neither |

### Usage

First, do a dry run. It runs every check and prints the install command, and it changes nothing:

```bash
QUAY_HOSTNAME=registry.example.com bash /root/install-mirror-registry.sh --dry-run
```

If all checks pass, run the same command without `--dry-run`. The script then does these steps:

1. It creates `/registry-data` and the four folders in it, with mode `0750`.
2. It unpacks the installer into `/registry-data/mirror-registry`.
3. It runs `./mirror-registry install` from that folder, with the three storage flags.
4. It writes the full output to `/registry-data/install-<time>.log`, with mode `0600`.
5. It requests `https://<QUAY_HOSTNAME>:8443/health/instance`. If the answer is not HTTP 200, it stops with an error.

The log has mode `0600` because it holds the password of `INIT_USER`, in its last lines. If you set
`INIT_PASSWORD`, the password is visible in the process list during the install, because the installer takes it as a
flag. The script hides it in its own output.

### What the script checks before the install

| Check | Why |
|---|---|
| Root, RHEL 9 family, `podman`, `openssl` and `ssh-keygen` present | The installer needs them |
| `QUAY_HOSTNAME` is a full name, with no port and no IP address | The installer does not accept an IP address |
| `QUAY_HOSTNAME` resolves to an address of this host | The last step of the installer contacts Quay at that name. `/etc/hosts` counts |
| The short host name resolves | The installer connects to the target host over SSH, by default `$(hostname)` as `root` |
| Port 8443 is free | Quay listens there |
| No data in the three storage folders, and no `quay-pod` | The script does not install over a registry. Use `mirror-registry upgrade` for that |
| The tarball holds `mirror-registry` and its three archives | The installer reads them from its own folder |
| `SSL_CERT` is valid for `QUAY_HOSTNAME` | A certificate for another name breaks every client |

### Test record

The dry run ran on 2026-11-22 on the same Rocky Linux 9.9 server. The real install did not run.

| Test | Result |
|---|---|
| No `QUAY_HOSTNAME` | `ERROR: set QUAY_HOSTNAME to the registry FQDN` |
| `QUAY_HOSTNAME=a.example.com:8443` | `ERROR: QUAY_HOSTNAME must not hold a port; set QUAY_PORT instead` |
| `QUAY_HOSTNAME=138.201.254.103` | `ERROR: QUAY_HOSTNAME must be a name, not an IP address` |
| `QUAY_HOSTNAME=kcs-ewd-registry` | `ERROR: QUAY_HOSTNAME must be a fully qualified name` |
| `QUAY_HOSTNAME=kcs-ewd-registry.getsolisvault.com`, with the Cloudflare proxy still on | `ERROR: ... resolves to 188.114.96.3 188.114.97.3 ... which is not an address of this host` |
| Hetzner's name for the IP, `static.103.254.201.138.clients.your-server.de` | All checks passed, and the script printed the install command |
| With `INIT_PASSWORD` set | The command showed `--initPassword '<hidden>'` |
| `SSL_CERT` without `SSL_KEY` | `ERROR: set both SSL_CERT and SSL_KEY to existing files, or neither` |
| After all dry runs | `/registry-data` did not exist |

### Open points

- SELinux is permissive on the test server. Nobody checked yet whether the installer labels the folders in
  `/registry-data` for containers. Check this before you set SELinux to enforcing.
- The installer connects over SSH with the key `~/.ssh/quay_installer`, per its `install --help`. Nobody checked yet
  what it adds to `~/.ssh/authorized_keys` of root. After the install, read that file and record the result here.
