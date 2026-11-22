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
| 5 | Host | Installs `tmux`, `ansible-core`, `jq`, `oc`, `kubectl` and `oc-mirror` with `install-cli-tools.sh` |
| 6 | Host | Starts a `tmux` session |
| 7 | Host | Splits the combined PEM file of the CA into a certificate chain and an unencrypted key |
| 8 | Host | Does a dry run of `install-mirror-registry.sh` |
| 9 | Host | Installs the mirror registry |
| 10 | Host and workstation | Makes sure that the registry works |
| 11 | Your workstation | Copies the playbooks and the pull secret to the host |
| 12 | Host | Encrypts the pull secret with Ansible Vault |
| 13 | Host | Uses the pull secret for an `oc-mirror` run |

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
not use it for real work. If the installer made the certificate, make each client trust its CA instead. Copy
`/registry-data/quay-install/quay-rootCA/rootCA.pem` from the host to the trust store of the client. Then log in
without `--tls-verify=false`:

```bash
podman login -u init "$REGISTRY_HOST:8443"
```

## 11. Copy the playbooks and the pull secret to the host

The mirror registry does not need the Red Hat pull secret. `oc-mirror` needs it to pull images from Red Hat. The
playbooks in `oc-mirror-ansible/` read it from an Ansible Vault file.

On your workstation, in the root of this repository, set the path of your pull secret:

```bash
LOCAL_PULL_SECRET=tools/pull-secret.txt
```

Copy the playbooks and the pull secret:

```bash
rsync -a --partial --progress --exclude .DS_Store \
    oc-mirror-ansible/ "$SSH_TARGET":/root/oc-mirror-ansible/
scp "$LOCAL_PULL_SECRET" "$SSH_TARGET":/root/tools/pull-secret.txt
ssh "$SSH_TARGET" 'chown -R root:root /root/oc-mirror-ansible /root/tools && chmod 600 /root/tools/pull-secret.txt'
```

`rsync` also copies files that git ignores. Before the copy, make sure that `git status --short --ignored
oc-mirror-ansible/` shows nothing.

## 12. Encrypt the pull secret with Ansible Vault

On the host, set the three paths:

```bash
PULL_SECRET=/root/tools/pull-secret.txt
PLAYBOOK_DIR=/root/oc-mirror-ansible
VAULT_FILE=$PLAYBOOK_DIR/vars/redhat-pull-secret.json
```

`PULL_SECRET` is the plain file from step 11. `VAULT_FILE` is the encrypted file. The playbooks read it from this path.

Make sure that the pull secret covers the Red Hat registries:

```bash
jq -r '.auths | keys[]' "$PULL_SECRET"
```

The output must include `quay.io` and `registry.redhat.io`. A `jq` parse error means that the file is damaged.
Download it again from https://console.redhat.com/openshift/install/pull-secret.

Choose a Vault password, and keep it in your password manager first. If you lose it, nobody can open the file. Then
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

For a manual run, make a temporary auth file. `oc-mirror` needs two logins in it: Red Hat, to pull, and this
registry, to push. Set the paths on the host:

```bash
VAULT_FILE=/root/oc-mirror-ansible/vars/redhat-pull-secret.json
AUTH_FILE=/run/user/0/containers/auth.json
```

`/run/user/0` is in memory, so the file does not stay after a reboot. It exists while root has a login session.

Write the auth file and add the registry login:

```bash
install -d -m 0700 "$(dirname "$AUTH_FILE")"
( umask 077; ansible-vault view "$VAULT_FILE" > "$AUTH_FILE" )
podman login --authfile "$AUTH_FILE" kcs-ewd-registry.getsolisvault.com:8443
```

`podman login` asks for the `init` user and its password from step 9. Give the file to `oc-mirror` with
`--authfile`, and delete it after the run:

```bash
oc-mirror --v2 --authfile "$AUTH_FILE" ...
shred -u "$AUTH_FILE"
```

The `...` stands for the real `oc-mirror` arguments, from the release guide. `oc-mirror` 2.0.0 also reads
`${XDG_RUNTIME_DIR}/containers/auth.json` without `--authfile`, as its `--help` shows. For root, that is the same
file. `--authfile` makes the choice visible in the command.

The clusters never get the Red Hat pull secret. They get a read-only robot account of this registry, as
[`docs/PREREQUISITES.md`](../../docs/PREREQUISITES.md) describes.

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
| 5 | Yes, before `tmux`, `ansible-core` and `jq` were added to the script. That package step did not run yet on the host |
| 6 | The operator ran the install in a terminal session. `tmux` use is not recorded |
| 7 | The commands, in a Rocky Linux 9 container with `openssl-3.5.9-1.el9_9` (the version on the host), with a test CA. Three combined files were tested: key first, key last, and the older `RSA PRIVATE KEY` form. Each gave a chain of 2 certificates with no key, a key with mode `600`, and a match. A chain with the CA certificate first gave `does NOT match`. No real CA file was used yet |
| 8 | Yes. All checks passed with the real name, without `SSL_CERT` and `SSL_KEY` |
| 9 | Yes, on 2026-11-22. `failed=0`, 4 minutes |
| 10 | Yes for the units, the pod, `/health/instance` (HTTP 200), no named volumes, and the three mounts. `podman login` not recorded yet |
| 11 | The `rsync` of the playbooks, as a dry run from macOS. The `scp` of the pull secret did not run |
| 12 | Yes, in a Rocky Linux 9 container with a dummy pull secret, `ansible-core-2.14.18-5.el9` and `jq-1.6-21.el9_9`. The Vault file had mode `600` and the header `$ANSIBLE_VAULT;1.1;AES256` |
| 13 | The auth file from the Vault file, in the same container, with mode `600`. `podman login` and `oc-mirror` did not run |
| Replace the TLS certificate | Not yet. Only the flags were read from `mirror-registry upgrade --help` of 2.0.13 |

On the test server, the install made `/registry-data/quay-install/quay-rootCA/rootCA.pem`, valid until 2029-09-11,
and `quay-config/ssl.cert` for `DNS:kcs-ewd-registry.getsolisvault.com`, valid until 2027-11-13. The server
certificate expires first. Replace it before that date, as "Replace the TLS certificate later" describes.
