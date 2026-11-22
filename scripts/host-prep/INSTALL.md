# Install a mirror registry host

This procedure prepares a RHEL 9 family host and installs the mirror registry for Red Hat OpenShift on it. Then it
stores the Red Hat pull secret for `oc-mirror`. You create a DNS record, prepare a TLS certificate, and run three
scripts in order. Each step shows the commands and the output that you must see before you continue.

The examples use the test server of 2026-11-22: Rocky Linux 9.9 at Hetzner, with the name
`kcs-ewd-registry.getsolisvault.com`. For another host, change the two variables in step 2.

| Step | Where | What it does |
|---|---|---|
| 1 | Your DNS provider | Creates the DNS record of the registry name |
| 2 | Your workstation | Sets the host variables |
| 3 | Your workstation | Copies the scripts and the Red Hat tarballs to the host |
| 4 | Host | Installs Podman with `install-podman.sh` |
| 5 | Host | Installs `tmux`, `ansible-core`, `jq`, `git`, `oc`, `kubectl` and `oc-mirror` with `install-cli-tools.sh` |
| 6 | Host | Starts a `tmux` session |
| 7 | Host | Splits the combined PEM file of the CA into a certificate chain and an unencrypted key |
| 8 | Host | Does a dry run of `install-mirror-registry.sh` |
| 9 | Host | Installs the mirror registry |
| 10 | Host and workstation | Makes sure that the registry works |
| 11 | Your workstation | Copies the repository and the pull secret to the host |
| 12 | Host | Encrypts the pull secret with Ansible Vault |
| 13 | Host | Uses the pull secret for an `oc-mirror` run |
| 14 | Host | Prepares the playbooks in `oc-mirror-ansible/` and does a dry run |

The details of each script are in [`README.md`](README.md).

## Before you start

- You have SSH access as root to the host, with a key.
- The `tools/` folder at the root of this repository holds the three Red Hat tarballs:
  `openshift-client-linux-amd64-rhel9.tar.gz`, `oc-mirror-rhel9-linux-amd64.tar.gz` and
  `mirror-registry-amd64.tar.gz`. Git ignores this folder.
- You have a fully qualified domain name (FQDN) for the registry, in a DNS zone that you control.
- You have the combined PEM file of your certificate authority (CA) for that name, with the key password. Step 7
  uses it.
- Port 8443 of the host is open to the registry clients.

## 1. Create the DNS record

The installer and every client reach the registry by its name. The name must resolve to the real address of the host.
The mirror registry does not accept an IP address as its host name.

In the DNS provider of your zone, create these records for the registry name:

| Type | Name | Value |
|---|---|---|
| A | The registry name | The IPv4 address of the host |
| AAAA | The registry name | The IPv6 address of the host. If the host has no IPv6, do not create this record |

If your provider can put a proxy or a CDN in front of a name, turn it off for this record. A proxy answers with its own
addresses, so the name does not resolve to the host.

In the lab test, the DNS provider was Cloudflare, with the zone `getsolisvault.com`:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| A | `kcs-ewd-registry` | `138.201.254.103` | DNS only (grey cloud) |
| AAAA | `kcs-ewd-registry` | `2a01:4f8:173:256f::2` | DNS only (grey cloud) |

The first lab record was "Proxied" (orange cloud). Cloudflare then answered with its own addresses, and the dry run in
step 8 stopped with `resolves to 188.114.96.3 188.114.97.3 ... which is not an address of this host`.

To make sure that the record is correct, ask the name servers of the zone first, then a public resolver:

```bash
dig +short NS getsolisvault.com
dig +short kcs-ewd-registry.getsolisvault.com @<one name server from the first command>
dig +short kcs-ewd-registry.getsolisvault.com @1.1.1.1
```

Each `dig` for the registry name must print the address of the host, `138.201.254.103` in the lab. The name servers
of the zone show a change at once. Other resolvers can keep the old answer until the TTL (cache time) of the record
ends. A Cloudflare address, for example `104.21.93.198`, means that the record is still proxied.

## 2. Set the host variables

On your workstation, go to the root of this repository and set two variables:

```bash
cd ~/gitRepos/openshift-upgrade
REGISTRY_HOST=kcs-ewd-registry.getsolisvault.com
SSH_TARGET=root@$REGISTRY_HOST
```

`REGISTRY_HOST` is the registry name. `SSH_TARGET` is the SSH login for the host.

## 3. Copy the scripts and the tarballs to the host

```bash
scp scripts/host-prep/install-podman.sh \
    scripts/host-prep/install-cli-tools.sh \
    scripts/host-prep/install-mirror-registry.sh \
    "$SSH_TARGET":/root/
rsync -a --partial --progress \
    --exclude .DS_Store --exclude pull-secret.txt \
    tools/ "$SSH_TARGET":/root/tools/
ssh "$SSH_TARGET" 'chown -R root:root /root/tools'
```

The `rsync` command does not copy the pull secret. Step 11 copies it. `rsync -a` keeps the user ID of your
workstation, so the `chown` command sets the owner to root.

macOS has `openrsync`, not GNU rsync 3.x. It does not support `--chown` or `--info=progress2`, so these commands do
not use them. If `rsync` is missing on the host, first run `ssh "$SSH_TARGET" dnf install -y rsync`.

Make sure that the tarballs arrived complete:

```bash
shasum -a 256 tools/*.tar.gz
ssh "$SSH_TARGET" 'sha256sum /root/tools/*.tar.gz'
```

The hashes on both sides must be the same.

## 4. Install Podman

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

## 5. Install the tools

```bash
bash /root/install-cli-tools.sh
```

The last lines must be similar to these:

```text
[install-cli-tools] tmux:      tmux 3.2a
[install-cli-tools] ansible:   ansible-vault [core 2.14.18]
[install-cli-tools] jq:        jq-1.6
[install-cli-tools] git:       git version 2.52.0
[install-cli-tools] oc:        Client Version: 5.0.1
[install-cli-tools] kubectl:   Client Version: v1.36.2
[install-cli-tools] oc-mirror: 2.0.0-202610201601.p2.gc4d52fa.assembly.stream.el9-c4d52fa
[install-cli-tools] oc-mirror supports OpenShift: [4.12,4.14,4.16,4.18,4.20,4.21,4.22,4.23,5.0]
[install-cli-tools] done
```

If the line `note: /usr/local/bin is not in PATH` appears, log out and log in again.

## 6. Start a tmux session

The mirror registry install takes several minutes. If your SSH connection drops, a job in `tmux` continues. Start
the session:

```bash
tmux new -s registry
```

If the connection drops, log in again and run `tmux attach -t registry`.

## 7. Prepare the TLS certificate and key

The CA delivers one combined PEM file for the registry name, for example `kcs-ewd-registry.getsolisvault.com.pem`.
It holds the private key and the certificates: the server certificate and the intermediate certificates of the CA.
The key in it has a password.

The installer needs two separate files: the certificate chain for `--sslCert`, and an unencrypted key for `--sslKey`.
This step makes both from the combined file.

If you skip this step, the installer makes its own CA and certificate. Then every client must trust that CA, as step
10 describes. In the lab test, the first install used the certificate of the installer, so step 7 was not used there.

### Copy the combined file to the host

On your workstation, run:

```bash
ssh "$SSH_TARGET" 'install -d -m 0700 /root/certs'
scp kcs-ewd-registry.getsolisvault.com.pem "$SSH_TARGET":/root/certs/
ssh "$SSH_TARGET" 'chmod 600 /root/certs/kcs-ewd-registry.getsolisvault.com.pem'
```

On the host, set the paths:

```bash
CERT_DIR=/root/certs
COMBINED_PEM=$CERT_DIR/kcs-ewd-registry.getsolisvault.com.pem
SSL_CERT=$CERT_DIR/fullchain.pem
SSL_KEY=$CERT_DIR/privkey.pem
```

`COMBINED_PEM` is the file from the CA. `SSL_CERT` and `SSL_KEY` are the two files that the installer gets.

Look at the blocks in the combined file:

```bash
grep -E '^-----BEGIN' "$COMBINED_PEM"
```

The output must show one key line and two or more `CERTIFICATE` lines. The key line is `-----BEGIN ENCRYPTED PRIVATE
KEY-----`, or `-----BEGIN RSA PRIVATE KEY-----` for an older format. The order of the lines does not matter for the
next commands.

### Write the certificate chain

```bash
sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$COMBINED_PEM" > "$SSL_CERT"
grep -c 'BEGIN CERTIFICATE' "$SSL_CERT"
grep -c 'PRIVATE KEY' "$SSL_CERT"
```

`sed` copies only the certificate blocks, in the order of the combined file. The first `grep` must print 2 or more.
The second must print `0`, so that no key goes into the certificate file.

### Decrypt the private key

The installer has `--sslKey` but no flag for a key password, as `mirror-registry install --help` shows. At the start of
its container, Quay reads the key, and nobody is there to type a password. So the key must be unencrypted.

`openssl pkey` reads the key directly from the combined file, and it skips the certificates. Run this command. It asks
for the key password:

```bash
( umask 077; openssl pkey -in "$COMBINED_PEM" -out "$SSL_KEY" )
head -1 "$SSL_KEY"
stat -c '%a %n' "$SSL_KEY"
```

`openssl` shows `Enter pass phrase for /root/certs/kcs-ewd-registry.getsolisvault.com.pem:`. After the password, `head`
must print `-----BEGIN PRIVATE KEY-----`, and `stat` must print `600`. `umask 077` makes sure that only root can read
the new file. If the password is wrong, `openssl` shows `Could not find private key` and writes no file.

Do not give the password with `-passin pass:<password>`. The password then goes into the shell history and the process
list.

### Check the certificate and key

```bash
openssl x509 -in "$SSL_CERT" -noout -checkhost kcs-ewd-registry.getsolisvault.com
openssl x509 -in "$SSL_CERT" -noout -enddate
key_hash=$(openssl pkey -in "$SSL_KEY" -pubout | sha256sum)
cert_hash=$(openssl x509 -in "$SSL_CERT" -noout -pubkey | sha256sum)
[ "$key_hash" = "$cert_hash" ] && echo "key matches certificate" || echo "ERROR: key does not match certificate"
```

| Command | Expected output |
|---|---|
| `-checkhost` | `Hostname kcs-ewd-registry.getsolisvault.com does match certificate` |
| `-enddate` | A `notAfter=` date in the future |
| The hash comparison | `key matches certificate`. It compares the public key of the key file with the public key in the certificate |

`openssl x509` reads only the first certificate of the file, so these checks also prove that the server certificate is
first. If `-checkhost` shows `does NOT match`, the CA put another certificate first. In that case, edit `$SSL_CERT` and
move the block of the server certificate to the top. Then do the checks again.

Export the two paths for the dry run in step 8. The script reads them and checks the name of the certificate again:

```bash
export SSL_CERT SSL_KEY
```

After the install, keep `$SSL_KEY` with mode `600`. When you have a copy of `$COMBINED_PEM` in a safe place, delete it
from the host. The password is the only protection of its key.

## 8. Do a dry run of the mirror registry install

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
step 9 before the dry run passes.

If you did step 7, `SSL_CERT` and `SSL_KEY` are set, and the printed command shows `--sslCert` and `--sslKey`. If you
did not, the installer makes its own certificate, and each client must then trust its CA. To set the password of
the `init` user, set `INIT_PASSWORD`. If you do not set it, the installer makes a random password.

## 9. Install the mirror registry

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

While Quay starts, the installer prints lines like this one. If they stop before the retries end, they are normal:

```text
FAILED - RETRYING: [root@kcs-ewd-registry]: Waiting up to 3 minutes for Quay to become alive at https://kcs-ewd-registry.getsolisvault.com:8443/health/instance (10 retries left).
```

The installer ends with a `PLAY RECAP` line that shows `failed=0`, and with these two lines:

```text
level=info msg="Quay installed successfully, config data is stored in /registry-data/quay-install"
level=info msg="Quay is available at https://kcs-ewd-registry.getsolisvault.com:8443 with credentials ...
```

On the test server, the install took 4 minutes, from 08:07:19 to 08:11:17 server time.

Read the password of the `init` user from the log:

```bash
tail -5 /registry-data/install-*.log
```

Keep the password in a password manager. The log has mode `0600`, so only root can read it.

If the install fails, the script shows `ERROR: mirror-registry install failed; read /registry-data/install-<time>.log`.
Read the last lines of that log before you try again.

## 10. Make sure that the registry works

On the host, look at the registry services and the data folders:

```bash
systemctl list-units 'quay*' --no-pager
podman pod ps
du -sh /registry-data/*
```

The output must be similar to this:

```text
quay-app.service   loaded active running Quay Container
quay-pod.service   loaded active exited  Infra Container for Quay
quay-redis.service loaded active running Redis Podman Container for Quay
```

`quay-pod.service` shows `exited` because it only starts the pod. `podman pod ps` must show `quay-pod` as `Running`.

To make sure that the data is in `/registry-data` and not in Podman volumes, run these commands:

```bash
podman volume ls
podman inspect quay-app --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
```

`podman volume ls` must show no volumes. The mounts must be `/registry-data/quay-storage`, `/registry-data/sqlite-storage`
and `/registry-data/quay-install/quay-config`.

Log in to the registry with the `init` user and the password from step 9. Red Hat's documentation gives this test
command. It works before any client trusts the certificate:

```bash
podman login -u init \
  -p <password> \
  kcs-ewd-registry.getsolisvault.com:8443 \
  --tls-verify=false
```

The output must be `Login Succeeded!`. Replace `<password>` with the real password.

Warning: a password after `-p` goes into the shell history and is visible in the process list. Use this command only
for a first test. For other logins, let `podman login` ask for the password:

```bash
podman login -u init --tls-verify=false kcs-ewd-registry.getsolisvault.com:8443
```

`--tls-verify=false` turns off the certificate check, so the connection is not protected against a false server. Do
not use it for real work. Make Podman trust the CA of the registry instead, as the next section shows.

### Trust the registry CA on the host

If the installer made the certificate (you did not do step 7), Podman does not trust it. A login without
`--tls-verify=false` then fails with this error:

```text
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

To make Podman on the host trust the CA that the installer made, run these commands on the host:

```bash
mkdir -p "/etc/containers/certs.d/kcs-ewd-registry.getsolisvault.com:8443"
cp /registry-data/quay-install/quay-rootCA/rootCA.pem "/etc/containers/certs.d/kcs-ewd-registry.getsolisvault.com:8443/ca.crt"
ls -l "/etc/containers/certs.d/kcs-ewd-registry.getsolisvault.com:8443/"
```

`ls` must show `ca.crt`. The folder name must be the host name and the port, as in the login command, and the file
must have the name `ca.crt`. Podman reads only that path for this registry. When `oc-mirror` pushes, it uses the same
trust. Thus you do this only once on each host.

Then log in without `--tls-verify=false`:

```bash
podman login -u init kcs-ewd-registry.getsolisvault.com:8443
```

The output must be `Login Succeeded!`. On another Linux client, copy `rootCA.pem` from the host into the same folder
on that client. If your certificate in step 7 came from a CA that the system already trusts, this section is not
necessary.

## 11. Copy the repository and the pull secret to the host

The mirror registry does not need the Red Hat pull secret. `oc-mirror` needs it to pull images from Red Hat. The
playbooks in `oc-mirror-ansible/` read it from an Ansible Vault file. This step copies the whole repository to the
host. The playbooks, the guides and the scripts then have the same paths as on your workstation.

`rsync` also copies files that git ignores. On your workstation, in the root of this repository, list them first:

```bash
git status --short --ignored | grep '^!!'
```

In the lab, the output was `.DS_Store` and `tools/`. `tools/` holds the tarballs and the plain pull secret, so the
copy leaves it out. If the output shows other files, add an `--exclude` for each one.

Set the path of your pull secret, and copy the repository and the pull secret:

```bash
LOCAL_PULL_SECRET=tools/pull-secret.txt
rsync -a --partial --progress --exclude .DS_Store --exclude /tools/ \
    ./ "$SSH_TARGET":/root/openshift-upgrade/
scp "$LOCAL_PULL_SECRET" "$SSH_TARGET":/root/tools/pull-secret.txt
ssh "$SSH_TARGET" 'chown -R root:root /root/openshift-upgrade /root/tools && chmod 600 /root/tools/pull-secret.txt'
```

The `/` at the start of `/tools/` matters. It matches only the `tools/` folder at the root of the repository. Without
it, `rsync` also leaves out `docs/tools/`. The copy includes `.git`, so the history is on the host too. Step 5 installed
`git`, so `git status` and `git log` work in `/root/openshift-upgrade`.

To see what the copy sends before you run it, add `-v --dry-run` to the `rsync` command. In the lab, the dry run
listed 742 entries and 48 MB, with no top-level `tools/` entry and no `pull-secret.txt`.

## 12. Encrypt the pull secret with Ansible Vault

On the host, set the three paths:

```bash
PULL_SECRET=/root/tools/pull-secret.txt
PLAYBOOK_DIR=/root/openshift-upgrade/oc-mirror-ansible
VAULT_FILE=$PLAYBOOK_DIR/vars/redhat-pull-secret.json
```

`PULL_SECRET` is the plain file from step 11. `VAULT_FILE` is the encrypted file. The playbooks read it from this path.

Make sure that the pull secret covers the Red Hat registries:

```bash
jq -r '.auths | keys[]' "$PULL_SECRET"
```

The output must include `quay.io` and `registry.redhat.io`. A `jq` parse error means that the file is damaged.
Download it again from https://console.redhat.com/openshift/install/pull-secret.

Choose a Vault password, and keep it in your password manager first. If you lose it, nobody can open the file. Step
14 uses the same password for the second Vault file. Then
encrypt the pull secret. When `ansible-vault` asks for the password, enter it two times:

```bash
ansible-vault encrypt "$PULL_SECRET" --output "$VAULT_FILE"
head -1 "$VAULT_FILE"
ansible-vault view "$VAULT_FILE" | jq -r '.auths | keys[]'
```

The `head` command must print `$ANSIBLE_VAULT;1.1;AES256`. The `view` command asks for the password and must list
the same registries as before. When both are correct, delete the plain file:

```bash
shred -u "$PULL_SECRET"
```

`ansible-vault encrypt --output` leaves the plain file as it was, so this step is necessary. `oc-mirror-ansible/.gitignore`
lists `vars/redhat-pull-secret.json`, so git does not commit the encrypted file either.

On your workstation, delete `$LOCAL_PULL_SECRET` after you keep a copy in your password manager. macOS has no `shred`
command, and on an SSD an overwrite does not reliably remove the old data, so use `rm "$LOCAL_PULL_SECRET"`.

## 13. Use the pull secret for an oc-mirror run

The playbooks in `oc-mirror-ansible/` do this step themselves. They decrypt the Vault file, add the registry login,
write a private auth file, and delete it after the run. The release guide,
[`oc-mirror-ansible/docs/release-mirroring-guide.md`](../../oc-mirror-ansible/docs/release-mirroring-guide.md), has
those runs.

For a manual run, you make a temporary auth file. `oc-mirror` needs two logins in it: Red Hat, to pull, and this
registry, to push. The pull secret is already an auth file. It is JSON in the form `{"auths": {...}}`, the same
format that `podman login` writes. So you do not convert it. You copy it to the auth file and add the login of this
registry to the copy.

### Set the paths

On the host, run:

```bash
VAULT_FILE=/root/openshift-upgrade/oc-mirror-ansible/vars/redhat-pull-secret.json
PULL_SECRET=/root/tools/pull-secret.txt
AUTH_FILE=/run/user/0/containers/auth.json
```

`VAULT_FILE` is the encrypted pull secret from step 12. `PULL_SECRET` is the plain file from step 11. Step 12
deletes it. `/run/user/0` is in memory, so `AUTH_FILE` does not stay after a reboot. It exists while root has a login
session.

### Write the auth file

`AUTH_FILE` can already exist, for example from an earlier `podman login`. The copy replaces it. To see which logins
it holds before you replace it, run `jq -r '.auths | keys[]' "$AUTH_FILE"`.

After step 12, write the auth file from the Vault file:

```bash
install -d -m 0700 "$(dirname "$AUTH_FILE")"
( umask 077; ansible-vault view "$VAULT_FILE" > "$AUTH_FILE" )
```

Before step 12, the plain file is still at `/root/tools/pull-secret.txt`. Look at what it holds, then copy it:

```bash
jq -r '.auths | keys[]' "$PULL_SECRET"
install -d -m 0700 "$(dirname "$AUTH_FILE")"
( umask 077; cp "$PULL_SECRET" "$AUTH_FILE" )
```

The `jq` output must list `quay.io` and `registry.redhat.io`, among others. When you finish step 12, use the Vault
form, and delete the plain file as step 12 describes.

### Add the registry login

```bash
podman login --authfile "$AUTH_FILE" -u init kcs-ewd-registry.getsolisvault.com:8443
```

`podman login` asks for the password of the `init` user from step 9. The registry does not need to be in the file
before the login. `podman login` adds its entry and keeps the `quay.io` and `registry.redhat.io` entries. The login
needs the CA trust from step 10. If it fails with `certificate signed by unknown authority`, do "Trust the registry
CA on the host" in step 10 first.

`podman login` writes the whole file again and drops the `email` fields. The `auth` values stay, and they are the
part that works. Thus, always log in on a copy, never on your only copy of the pull secret.

### Check the auth file

```bash
jq -r '.auths | keys[]' "$AUTH_FILE"
for r in registry.redhat.io quay.io kcs-ewd-registry.getsolisvault.com:8443; do printf '%s: ' "$r"; podman login --get-login --authfile "$AUTH_FILE" "$r"; done
oc image info --registry-config "$AUTH_FILE" --filter-by-os linux/amd64 registry.redhat.io/ubi9/ubi-minimal:latest | head -2
```

| Command | Expected output |
|---|---|
| `jq` | `kcs-ewd-registry.getsolisvault.com:8443` beside `quay.io` and `registry.redhat.io` |
| The `for` loop | The user name of each login. For this registry, `init` |
| `oc image info` | A `Name:` line and a `Digest:` line. The command reads the image details and downloads no image |

If the pull secret is not valid, `oc image info` shows `unauthorized: Please login to the Red Hat Registry`.

To make sure that the auth file is the combined file, compare its logins with the logins of the pull secret:

```bash
jq -r '.auths | keys[]' "$PULL_SECRET"
jq -r '.auths | keys[]' "$AUTH_FILE"
```

The auth file must have every login of the pull secret, plus the registry. In the lab, the output was:

```text
[root@kcs-ewd-registry ~]# jq -r '.auths | keys[]' "$PULL_SECRET"
cloud.openshift.com
quay.io
registry.connect.redhat.com
registry.redhat.io
[root@kcs-ewd-registry ~]# jq -r '.auths | keys[]' "$AUTH_FILE"
cloud.openshift.com
kcs-ewd-registry.getsolisvault.com:8443
quay.io
registry.connect.redhat.com
registry.redhat.io
```

The four Red Hat logins are in both lists, and `kcs-ewd-registry.getsolisvault.com:8443` is only in the auth file.
After step 12, `PULL_SECRET` no longer exists. Then compare with `ansible-vault view "$VAULT_FILE" | jq -r '.auths |
keys[]'`.

### Run oc-mirror and delete the auth file

Give the file to `oc-mirror` with `--authfile`, and delete it after the run:

```bash
oc-mirror --v2 --authfile "$AUTH_FILE" ...
shred -u "$AUTH_FILE"
```

The `...` stands for the real `oc-mirror` arguments, from the release guide. `oc-mirror` 2.0.0 also reads
`${XDG_RUNTIME_DIR}/containers/auth.json` without `--authfile`, as its `--help` shows. For root, that is the same
file, and `podman pull` uses it too. `--authfile` makes the choice visible in the command.

The clusters never get the Red Hat pull secret. They get a read-only robot account of this registry, as
[`docs/PREREQUISITES.md`](../../docs/PREREQUISITES.md) describes.

## 14. Prepare the playbooks and do a dry run

The playbooks in `oc-mirror-ansible/` do not use `AUTH_FILE` from step 13. Each run makes its own auth file from two
Vault files and gives it to `oc-mirror`. At the end of the run, also after a failure, the playbook deletes the file. `playbook.yml` needs three
things on the host before the first run:

| Item | Why |
|---|---|
| `vars/redhat-pull-secret.json` | The encrypted pull secret. Step 12 makes it |
| `vars/credentials.yml` | The encrypted login of this registry: `target_registry_user` and `target_registry_password` |
| `vars/env-lab.yml` | The values of this lab, with no secrets. It is in git, so step 11 copied it |

Git ignores `vars/credentials.yml` and `vars/redhat-pull-secret.json`, as `oc-mirror-ansible/.gitignore` shows.

`vars/env-lab.yml` holds these values:

| Variable | Lab value | Default in the playbooks |
|---|---|---|
| `base_path` | `/registry-data/oc-mirror`, because this host has no `/data` | `/data/oc-mirror` |
| `oc_mirror_bin` | `/usr/local/bin/oc-mirror`, where step 5 installs it | `<playbook folder>/oc-mirror` |
| `target_registry_fqdn` | `kcs-ewd-registry.getsolisvault.com:8443` | `registry-lab.example.com:8443` |
| `mirror_namespace` | `ocp4v2`. Change it to the organization name that you use at work | `ocp4v2` |

At work, copy `vars/env.yml.example` to `vars/env-<name>.yml` and set the values of that host. The command of each run
then differs only by the name of the file.

### Set the paths

On the host, run:

```bash
PLAYBOOK_DIR=/root/openshift-upgrade/oc-mirror-ansible
BASE_PATH=/registry-data/oc-mirror
cd "$PLAYBOOK_DIR"
```

`BASE_PATH` must be the `base_path` of `vars/env-lab.yml`. The checks after the dry run use it. The playbook makes the
folders under it.

### Make the Vault file of the registry login

Use the same Vault password as in step 12. `--ask-vault-pass` asks for one password, and that password must open both
files. This command reads the `init` password from the install log, so the password does not show on the screen:

```bash
grep -o 'credentials (init, [^)]*' /registry-data/install-*.log | sed 's/.*, //' | { read -r pw; printf 'target_registry_user: "init"\ntarget_registry_password: "%s"\n' "$pw"; } | ansible-vault encrypt --output vars/credentials.yml
```

`ansible-vault` asks for the new Vault password two times. Then make sure that the file is encrypted and correct:

```bash
head -1 vars/credentials.yml
stat -c '%a %n' vars/credentials.yml
ansible-vault view vars/credentials.yml | sed 's/password: .*/password: <hidden>/'
```

| Command | Expected output |
|---|---|
| `head` | `$ANSIBLE_VAULT;1.1;AES256` |
| `stat` | `600 vars/credentials.yml` |
| `ansible-vault view` | `target_registry_user: "init"` and `target_registry_password: <hidden>` |

`init` is the first user of the registry, with full rights. For the lab test, it is the login. Before production, use
a robot account with push rights on one organization only, as
[`docs/PREREQUISITES.md`](../../docs/PREREQUISITES.md) describes.

### Do the dry run

Start a `tmux` session first, as in step 6. Then run:

```bash
ansible-playbook playbook.yml --ask-vault-pass -e @vars/env-lab.yml -e oc_mirror_dry_run=true
```

The default workflow is `m2d` (mirror to disk). It reads from Red Hat and writes an archive under `$BASE_PATH`. It
does not push to the registry. With `oc_mirror_dry_run=true`, `oc-mirror` copies no images. It only lists them.

The run must end with `failed=0` in `PLAY RECAP`. Then look at the results:

```bash
cat "$BASE_PATH/imagesets/archive.yaml"
ls "$BASE_PATH/archive/working-dir/dry-run/"
ls -la "$BASE_PATH/private/"
```

The ImageSet must show the channel `eus-4.18`, `minVersion: 4.18.17` and `maxVersion: 4.18.17`, `graph: true`, and
the `cincinnati-operator` package from `redhat-operator-index:v4.18`. These are the defaults in `playbook.yml`. The
release guide says that the dry run writes `mapping.txt` and `missing.txt` in `working-dir/dry-run/`. `mapping.txt`
lists the images, and `missing.txt` lists the images that `oc-mirror` cannot get. `private/` must be empty, because the
playbook deleted the auth file.

For the real runs after the dry run, read
[`oc-mirror-ansible/docs/release-mirroring-guide.md`](../../oc-mirror-ansible/docs/release-mirroring-guide.md). A push
to this registry (`d2m` or `m2m`) also needs the organization `ocp4v2` in Quay, because the playbook pushes to
`$REGISTRY/ocp4v2`.

## Replace the TLS certificate later

You can replace the certificate after the install with `mirror-registry upgrade`. In version 2.0.13, `upgrade` has the
same `--sslCert` and `--sslKey` flags as `install`, as `mirror-registry upgrade --help` shows.

Give `upgrade` the same four paths as the install. Red Hat's documentation gives this rule: for an install with
`--quayHostname` and `--quayRoot`, `upgrade` needs the same values. This install also sets `--quayStorage`
and `--sqliteStorage`. Without them, `upgrade` uses its defaults, the empty Podman volumes `quay-storage` and
`sqlite-storage`. The registry then starts with no images and no users.

Warning: give all four paths to every `mirror-registry upgrade`, not only for a certificate. If a path is missing, the
registry starts with empty storage.

Run the command as root from the unpacked installer folder, with all four paths and the new certificate files:

```bash
cd /registry-data/mirror-registry
./mirror-registry upgrade -v \
  --quayHostname kcs-ewd-registry.getsolisvault.com:8443 \
  --quayRoot /registry-data/quay-install \
  --quayStorage /registry-data/quay-storage \
  --sqliteStorage /registry-data/sqlite-storage \
  --sslCert "$SSL_CERT" \
  --sslKey "$SSL_KEY"
```

Before you run it, prepare the new combined file as in step 7. Copy it to `/root/certs`, and set the paths. Write
the chain, decrypt the key, and do all the checks. The key for `--sslKey` must be unencrypted.

After the upgrade, do step 10 again. These points also apply:

- Clients that trust the CA of the installer must trust the new issuer instead. Most clients already trust a public
  issuer such as Let's Encrypt.
- The mirror registry does not rotate certificates (Red Hat RFE-4051). A Let's Encrypt certificate expires after 90
  days or less, so each renewal must run this `upgrade` again. A `certbot` deploy hook can do that.
- A Red Hat solution article reports that `quay-app` did not start after a certificate replacement, on Quay 3.6 and
  3.7 with RHEL 8. After the upgrade, look at `systemctl list-units 'quay*'`.

Sources:

- Red Hat OpenShift 4.22 documentation, chapter 4,
  [the mirror registry for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/disconnected_environments/installing-mirroring-creating-registry)
- Red Hat solution 6980268, [replacement of the mirror registry certificate](https://access.redhat.com/node/6980268)
- Red Hat solution 7017058, [quay-app does not start after a certificate replacement](https://access.redhat.com/node/7017058)
- [RFE-4051](https://issues.redhat.com/browse/RFE-4051), no automatic certificate rotation

## Status of this procedure

| Step | Tested on the test server |
|---|---|
| 1 | Yes. Cloudflare, "DNS only". The first record was "Proxied", and the dry run refused it |
| 2 and 3 | Yes. The hashes matched after the copy. The `rsync` command is now the `openrsync` form, tested as a dry run |
| 4 | Yes, with a second run and a test as a rootless user |
| 5 | Yes on the host, before `tmux`, `ansible-core`, `jq` and `git` were added. The package step ran in a Rocky Linux 9 container: the four versions above, and `already installed` on a second run |
| 6 | The operator ran the install in a terminal session. `tmux` use is not recorded |
| 7 | The commands, in a Rocky Linux 9 container with `openssl-3.5.9-1.el9_9` (the version on the host), with a test CA. Three combined files were tested: key first, key last, and the older `RSA PRIVATE KEY` form. Each gave a chain of 2 certificates with no key, a key with mode `600`, and a match. A chain with the CA certificate first gave `does NOT match`. No real CA file was used yet |
| 8 | Yes. All checks passed with the real name, without `SSL_CERT` and `SSL_KEY` |
| 9 | Yes, on 2026-11-22. `failed=0`, 4 minutes |
| 10 | Yes for the units, the pod, `/health/instance` (HTTP 200), no named volumes, and the three mounts. A trusted `podman login` on the host passed with `rootCA.pem` as `ca.crt` (temporary `--cert-dir`), and failed with `certificate signed by unknown authority` without it. The operator saw the same error before the `certs.d` step |
| 11 | The `rsync` of the whole repository, as a dry run from macOS with `-v`: 742 entries, 48 MB, no top-level `tools/`, no `pull-secret.txt`, `docs/tools/` kept. The `scp` of the pull secret did not run |
| 12 | Yes, in a Rocky Linux 9 container with a dummy pull secret, `ansible-core-2.14.18-5.el9` and `jq-1.6-21.el9_9`. The Vault file had mode `600` and the header `$ANSIBLE_VAULT;1.1;AES256` |
| 13 | On the host with the real pull secret (plain file, before step 12), by the operator on 2026-11-22: the auth file had the four Red Hat logins of the pull secret plus `kcs-ewd-registry.getsolisvault.com:8443`. Before that, with a dummy pull secret: the `email` fields were dropped, mode `600`, and `oc image info` gave `unauthorized` with no login. `oc image info` with the real file and `oc-mirror` did not run yet |
| 14 | In a Rocky Linux 9 container with `ansible-core`, both playbooks, a stand-in `oc-mirror` script, a test pull secret and a `--vault-password-file`. With `-e @vars/env-lab.yml`: `failed=0`, `/usr/local/bin/oc-mirror` ran with `--authfile /registry-data/oc-mirror/private/mirroring.json` (the registry and the Red Hat logins) and `--dry-run`, and no auth file was left. Without the file, the old defaults were used unchanged. `-e mirror_namespace=ocp4` gave the push target `docker://kcs-ewd-registry.getsolisvault.com:8443/ocp4`. The `credentials.yml` command ran on a terminal (`script` pty): two password prompts, `Encryption successful`, mode `600`. The real `oc-mirror` and the dry-run lists did not run yet |
| Replace the TLS certificate | Not yet. Only the flags were read from `mirror-registry upgrade --help` of 2.0.13 |

On the test server, the install made `/registry-data/quay-install/quay-rootCA/rootCA.pem`, valid until 2029-09-11,
and `quay-config/ssl.cert` for `DNS:kcs-ewd-registry.getsolisvault.com`, valid until 2027-11-13. The server
certificate expires first. Replace it before that date, as "Replace the TLS certificate later" describes.
