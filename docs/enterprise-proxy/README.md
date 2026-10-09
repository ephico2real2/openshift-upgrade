# Step 2: retrofit a disconnected cluster to reach Red Hat through the enterprise proxy

| | |
|---|---|
| Status | Proposed runbook. Not run on any of our clusters, not approved by security |
| Researched | 2026-10-07, against `openshift/openshift-docs` branches `enterprise-4.18`, `enterprise-4.21` and `enterprise-4.22`; earlier findings in [`openshift-update-egress.html`](../openshift-update-egress.html) (2026-09-25) |
| Starting point | OpenShift 4.18.17 on `eus-4.18`, disconnected: IDMS/ITMS from oc-mirror pointing at the datacenter's mirror registry (`registry-dc1` in the examples), mirrored CatalogSources, a local OpenShift Update Service, default OperatorHub sources off |
| Where commands run | The mirroring bastion of the cluster's datacenter ([`PREREQUISITES.md`](../PREREQUISITES.md)); it needs `oc`, `jq`, Ansible Vault and the cluster API on 6443 |
| End point | The cluster pulls images, the update graph and signatures from Red Hat through the corporate proxy. No mirror, no local Update Service, no two-headed DNS |
| In the design docs | Option 1 ([`DESIGN-DECISIONS.md`](../DESIGN-DECISIONS.md)); this runbook is its rollout order, phase by phase |

Step 1 ([`oc-mirror-ansible/`](../../oc-mirror-ansible/README.md)) still means we mirror everything
ourselves. Step 2 removes the mirror: the cluster-wide `Proxy` resource sends the platform's
traffic to the enterprise proxy, which lets through only Red Hat's documented hosts. Everything
the cluster needs from Red Hat then arrives the same way a connected cluster gets it.

**Red Hat has no single "disconnected to connected" procedure.** The closest document is the reverse
("Converting a connected cluster to a disconnected cluster",
`disconnected/connected-to-disconnected.adoc`), whose "Restoring the network" section deletes the
mirror objects. This runbook puts that together with the documented proxy, pull secret, update
server and OperatorHub procedures. Where a step rests on our own reading and not on a Red Hat
sentence, it says so.

## How it fits together

The threat model of this design, with each flow, its caller and its control, is in
[`THREAT-MODEL.md`](THREAT-MODEL.md).

```text
RED HAT          quay.io + CDN, registry.redhat.io, api.openshift.com, mirror.openshift.com
                    ^ TCP 443, HTTP CONNECT
ENTERPRISE PROXY allowlist of Red Hat hosts only; the firewall lets only the proxy out
                    ^ node IPs only (pod traffic leaves with the node IP too, see "Only core components")
CLUSTER          Proxy CR -> CVO, CRI-O, OLM, Insights, image registry operator ...
                 workload namespaces: no proxy variables from the platform
                 allowedRegistries limits what any pod may pull
```

**No two-headed DNS.** With HTTP CONNECT the client sends the proxy only `host:443`, and the proxy
resolves the name. Nodes resolve the proxy's own name and the internal names in `noProxy`, nothing
public. Our internal DNS stays as it is. Two conditions from the research: add
`.apps.<cluster>.<domain>` to `noProxy` (the authentication and console operators check their own
routes through the proxy), and keep NTP on an internal source (UDP 123 does not go through a proxy).

**Step 2 needs no local Update Service.** The cluster reads its graph from `api.openshift.com`
like any connected cluster. The local OSUS is retired in phase 6. (Step 3 is different: its
clusters have no egress and need one, see [`quay-onprem/`](../quay-onprem/README.md).)

## What each phase does to the nodes

Changes that touch no nodes go first; the proxy gets its own maintenance window; the mirror objects
come out only after a connected update has worked.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../diagrams/three-steps/retrofit.dark.png">
  <source srcset="../diagrams/three-steps/retrofit.light.png">
  <img alt="The Step 2 runbook converts a disconnected cluster in ten phases. Phases 0 to 3 touch no nodes beyond a CRI-O reload: approval, backup, the Red Hat pull secret and the image allowlist. Phase 4 turns on the cluster-wide proxy and drains and reboots every node. Phases 5 to 7 lock workloads out of the proxy, point update checks at Red Hat and move the operator catalogs, with no node effect. Phase 8 runs one update with the mirror still in place, and only then phase 9 removes the mirror, which drains the nodes again." src="../diagrams/three-steps/retrofit.light.png">
</picture>

*Proposed runbook, not run on any cluster. The table below carries the same phases and node effects.*

| Phase | What | Node effect |
|---|---|---|
| 0 · Approve and prepare outside the cluster | Security sign-off, proxy allowlist, firewall, Red Hat credentials | None |
| 1 · Back up and check | Save every object this runbook changes | None |
| 2 · Pull secret | Merge Red Hat's pull secret into `openshift-config/pull-secret` | None ("without draining or rebooting the node") |
| 3 · Image policy | `allowedRegistries` | CRI-O reload, no drain |
| 4 · Proxy | `user-ca-bundle`, then `proxy/cluster` | **Drain and reboot, every node** |
| 5 · Optional: keep workloads off the proxy | Only if security asks; app teams that already use the proxy must be excluded | None |
| 6 · Update graph | Clear `spec.upstream`, keep the channel | None |
| 7 · Catalogs | Default `redhat-operators` source back on, Subscriptions moved to it | None (operators may update) |
| 8 · First connected update | One z-stream or the planned EUS update | Normal update |
| 9 · Remove the mirror | Delete IDMS/ITMS/ICSP, mirrored CatalogSources, local OSUS | **Drain, possibly reboot** |

Do it per cluster, lower environments first.

## Phase 0: approve and prepare outside the cluster

1. **Security sign-off** on the host list below and on the controls in
   [`openshift-update-egress.html`](../openshift-update-egress.html), "Security controls for the
   approval request". The open telemetry question (D3) and TLS interception question (D4) must be
   answered before phase 2 and phase 4.
2. **Firewall:** cluster nodes may reach the proxy and internal services only. Nothing goes out
   directly.
3. **Proxy:** highly available. A proxy outage stops every image pull from Red Hat, so it needs the
   availability the docs demand of a mirror registry. Give the clusters their own listener or
   policy with this allowlist only, all TCP 443:

   | Host | Why | Needed |
   |---|---|---|
   | `quay.io`, `cdn.quay.io`, `cdn01.quay.io` … `cdn06.quay.io` (or `*.quay.io`) | Release payload and image layers; `registry.redhat.io` layers come from the Quay CDN too | Always |
   | `registry.redhat.io` | Core images, operator catalogs and operator images | Always |
   | `api.openshift.com` | "API endpoint for cluster tokens and update checks" | Always |
   | `mirror.openshift.com` | Release signatures ("the Cluster Version Operator needs only a single functioning source") | Always |
   | `quayio-production-s3.s3.amazonaws.com` | "Required to access Quay image content in AWS" | As listed; ask Red Hat whether on-prem needs it |
   | `console.redhat.com`, `sso.redhat.com` | Cluster tokens and authentication | Listed under updates; whether updates fail without them is unverified |
   | `registry.access.redhat.com`, `access.redhat.com` | Ecosystem Catalog images and their signature store | If anything pulls from that registry |
   | `cert-api.access.redhat.com`, `api.access.redhat.com`, `infogw.api.openshift.com` | Telemetry and Insights | Only if D3 keeps telemetry on |
   | `registry.connect.redhat.com` | Certified and partner operators | Only if we use them (e.g. the IBM Fusion sample) |
   | `icr.io`, `cp.icr.io` | IBM Cloud Paks | Only for IBM content |

   - Source: "Configuring your firewall" (`installing/install_config/configuring-firewall.adoc`).
     The host list is the same from 4.18 to 4.22.
   - "do not add a wildcard entry such as `*.quay.io` to your denylist": downloads redirect to
     `cdn01.quay.io` and similar.
   - **Proxy login:** prefer a proxy that admits the cluster's node subnets without a password. A
     user name and password in `httpProxy` are readable by anyone who can read `proxy/cluster`, and
     they end up in the environment of every platform pod.
4. **TLS interception (D4):** until Red Hat Support answers, exempt the hosts above from
   interception. If the proxy does intercept, the proxy's CA must go into `trustedCA` (phase 4)
   and `sso.redhat.com` must not be re-encrypted (`modules/cluster-wide-proxy-preqs.adoc`, ROSA/OSD
   context).
5. **Red Hat credentials:** a Registry Service Account for `registry.redhat.io` ("recommended… in
   place of an individual's Customer Portal credentials"), or the organisation's pull secret from
   `console.redhat.com`. Keep it Vault-encrypted as in Step 1 (`vars/redhat-pull-secret.json`).
6. **Test from a node subnet before touching the cluster**, from a host on the same subnet:

   ```bash
   export https_proxy=http://proxy.example.com:3128
   for h in quay.io cdn01.quay.io registry.redhat.io api.openshift.com mirror.openshift.com; do
     printf '%-24s ' "$h"; curl -s -o /dev/null -m 10 -w '%{http_code}\n' "https://$h/" || echo FAIL
   done
   curl -s -o /dev/null -m 10 -w '%{http_code}\n' https://www.example.com/   # must be denied
   unset https_proxy
   curl -s -o /dev/null -m 10 https://quay.io/ && echo "DIRECT EGRESS OPEN - fix the firewall"
   ```

   Any HTTP code from a Red Hat host means it is reachable; `FAIL` or `000` means it is not.

## Phase 1: back up and check

```bash
export CLUSTER=prod1                       # used in file names only
B=~/retrofit-$CLUSTER-$(date +%F); mkdir -p "$B"; chmod 700 "$B"
oc get proxy/cluster -o yaml                         > "$B/proxy.yaml"
oc get image.config.openshift.io/cluster -o yaml     > "$B/image-config.yaml"
oc get clusterversion version -o yaml                > "$B/clusterversion.yaml"
oc get operatorhub cluster -o yaml                   > "$B/operatorhub.yaml"
oc get imagedigestmirrorset,imagetagmirrorset,imagecontentsourcepolicy -o yaml > "$B/mirror-sets.yaml"
oc get catalogsource -n openshift-marketplace -o yaml > "$B/catalogsources.yaml"
oc get subscriptions.operators.coreos.com -A -o yaml  > "$B/subscriptions.yaml"
oc get configmap -n openshift-config -o yaml          > "$B/openshift-config-cms.yaml"
oc get secret/pull-secret -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' > "$B/pull-secret.json"
chmod 600 "$B"/*
```

`pull-secret.json` holds credentials. Keep the backup folder on the bastion only, and delete it once
the retrofit is signed off.

Check the cluster is healthy and nothing will block a reboot:

```bash
oc get clusterversion
oc get co | awk 'NR==1 || $3!="True" || $4!="False" || $5!="False"'   # only the header should print
oc get mcp                         # UPDATED=True, DEGRADED=False, and none paused:
oc get mcp -o custom-columns=NAME:.metadata.name,PAUSED:.spec.paused
oc get pdb -A                      # PDBs with ALLOWED DISRUPTIONS 0 will stall the drain in phase 4
```

A worker pool left paused after an EUS update will not pick up the proxy; unpause it first
(`oc patch mcp/worker --type merge -p '{"spec":{"paused":false}}'`).

**Inventory what the platform talks to inside our network.** Every internal host that a platform
component or OLM-installed operator contacts must be in `noProxy`, or its traffic goes to the proxy
and is denied. Check at least:

| Internal service | Used by |
|---|---|
| The mirror registry (until phase 9) | CRI-O, through IDMS/ITMS |
| LDAP or OIDC identity provider | Authentication operator |
| vCenter (vSphere): its address and the machine IP range | Machine API, CSI driver ("You must include vCenter's IP address…") |
| Alertmanager receivers, remote-write targets | Monitoring |
| Log forwarding targets (Splunk, syslog, Loki) | Logging operator |
| Internal Git, Vault, artifact repositories | OpenShift GitOps and other OLM operators: they "inherit the cluster-wide proxy settings on their deployments" |
| The cluster's own API and apps domains | Everything |

And list the registries running pods pull from today, for phase 3:

```bash
oc get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | awk -F/ '{print $1}' | sort | uniq -c | sort -rn
oc get image.config.openshift.io/cluster -o jsonpath='{.spec.registrySources}{"\n"}'
```

## Phase 2: Red Hat credentials in the global pull secret

The cluster keeps its mirror registry login until phase 9; the Red Hat entries are added beside it.

```bash
cd ~/openshift-upgrade/oc-mirror-ansible
umask 077
ansible-vault view vars/redhat-pull-secret.json --vault-password-file ~/.vault-pass-oc-mirror > /dev/shm/rh.json

# Merge: keeps the mirror registry entry, adds quay.io, registry.redhat.io, ...
jq -s '.[0] * .[1]' "$B/pull-secret.json" /dev/shm/rh.json > /dev/shm/merged.json

# Only if D3 says telemetry and Insights stay OFF: drop the entry that turns them on
jq 'del(.auths["cloud.openshift.com"])' /dev/shm/merged.json > /dev/shm/m && mv /dev/shm/m /dev/shm/merged.json

jq -r '.auths | keys[]' /dev/shm/merged.json          # review the registry names, not the tokens
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/shm/merged.json
shred -u /dev/shm/rh.json /dev/shm/merged.json
```

- **Node effect:** none. "When the MCO detects any of the following changes, it applies the update
  without draining or rebooting the node: … Changes to the global pull secret" (`snippets/node-icsp-no-drain.adoc`).
  It still "rolls out to all nodes, which can take some time": wait for `oc get mcp` to settle.
- **Telemetry:** "Enabling remote health reporting enables both Insights Operator and Telemetry"
  and is done by adding the `cloud.openshift.com` entry (`modules/enabling-remote-health-reporting.adoc`).
  Leaving it out keeps them off and drops three hosts from the allowlist.
- Changing the pull secret "without first starting an ownership transfer" in OpenShift Cluster
  Manager "causes the cluster to stop reporting Telemetry metrics". That only matters if telemetry is on.

Check a node can read it:

```bash
NODE=$(oc get nodes -o name | head -1)
oc debug $NODE -- chroot /host jq -r '.auths | keys[]' /var/lib/kubelet/config.json
```

## Phase 3: limit what any pod may pull

Opening `quay.io` opens anyone's public images. `allowedRegistries` lists repositories, not just
registries, and "all registries, including `registry.redhat.io`, `quay.io`… are blocked unless
explicitly listed" (`snippets/allowed-registries-warning.adoc`).

```bash
oc get image.config.openshift.io/cluster -o jsonpath='{.spec.registrySources}{"\n"}'
```

If that shows `blockedRegistries` (disconnected setups sometimes block `quay.io/openshift-payload`),
remove it first: the two settings cannot be used together.

```bash
oc patch image.config.openshift.io/cluster --type merge -p '{
  "spec": {"registrySources": {"allowedRegistries": [
    "quay.io/openshift-release-dev",
    "registry.redhat.io",
    "registry.access.redhat.com",
    "image-registry.openshift-image-registry.svc:5000",
    "registry-dc1.example.com:8443"
  ]}}}'
```

- **`image-registry.openshift-image-registry.svc:5000`:** the in-cluster registry. Leaving it out
  breaks builds and image streams.
- **`registry-dc1.example.com:8443`:** the datacenter's mirror registry, with its path if pulls use one. Keep it
  until phase 9.
- **Everything else from the phase 1 inventory:** add each registry that running pods pull from,
  or those pods fail on their next pull. Add `registry.connect.redhat.com` for certified operators.
- **Node effect:** "Changes to the `/etc/containers/policy.json` file do not require the node to drain";
  CRI-O reloads.
- **Open question for Red Hat Support:** whether `quay.io/openshift-release-dev` covers everything a
  connected cluster pulls from `quay.io`. Watch for `ErrImagePull` with "not allowed" after phase 8.
- **Stricter rule for applications (Kyverno):** this list has to include everything the platform
  pulls. Kyverno's standard allowed-registries policy, in [`../image-policies/`](../image-policies/),
  narrows application namespaces further at admission: the list is a ConfigMap in the cluster,
  with an audit mode first and per-team exceptions. It adds to
  `allowedRegistries` and does not replace it: admission never sees build `FROM` pulls, static pods
  or pulls run on a node.

## Phase 4: the cluster-wide proxy (maintenance window)

Saving the proxy "reboots all nodes in your cluster". The nodes are drained and rebooted one pool at
a time, by `maxUnavailable`. Book a window as for an update.

**4a. The proxy's CA**, if its certificate is not signed by a public CA in the RHCOS bundle, or if
it intercepts TLS. The key must be named `ca-bundle.crt`, and the ConfigMap must exist before the
proxy refers to it:

```bash
oc create configmap user-ca-bundle -n openshift-config --from-file=ca-bundle.crt=corp-proxy-ca.pem
```

If `user-ca-bundle` already exists (our mirror CA is often in it, from install time), add the proxy
CA to the same file instead of replacing it:

```bash
oc get cm user-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' > /dev/shm/bundle.pem
cat corp-proxy-ca.pem >> /dev/shm/bundle.pem
oc set data configmap/user-ca-bundle -n openshift-config --from-file=ca-bundle.crt=/dev/shm/bundle.pem
```

**4b. The proxy object.** Only `proxy/cluster` exists; "no additional proxies can be created".

```bash
cat > /dev/shm/proxy-patch.yaml <<'EOF'
spec:
  httpProxy: http://proxy.example.com:3128
  httpsProxy: http://proxy.example.com:3128
  noProxy: .apps.prod1.example.com,api-int.prod1.example.com,.example.com,10.10.0.0/16,registry-dc1.example.com,ldap.example.com,vcenter.example.com
  readinessEndpoints:
  - https://mirror.openshift.com
  - https://quay.io
  trustedCA:
    name: user-ca-bundle
EOF
oc patch proxy/cluster --type merge --patch-file /dev/shm/proxy-patch.yaml
```

- **`httpsProxy`** is the proxy's own URL. Use `http://` unless the proxy really speaks TLS on that
  port: "most proxies report an error if they are configured to use `https` but they only support
  `http`. This failure message may not propagate to the logs."
- **`noProxy`:**
  - The machine, cluster and service networks, `localhost`, `.cluster.local`, `.svc` and the internal
    API are added for us (see `status.noProxy`). Node IPs outside `machineNetwork` are not: add them.
  - Internal names must be listed by name: "you must explicitly specify that FQDN… You cannot use the
    IP address or CIDR range that encapsulates the domain." That covers the mirror registry and
    every host in the phase 1 inventory. `.example.com` matches all subdomains.
  - `.apps.<cluster>.<domain>` is required (no two-headed DNS, above).
  - Ports are not allowed except for IPv6 addresses.
- **`readinessEndpoints`:** checked through the proxy before the settings are written to status.
  Use hosts on our allowlist; the docs' example (`www.google.com`) would be denied.
- **Leave `buildDefaults` and workload proxy variables unset.** "The system-wide proxy affects system
  components only, not user workloads."

**Watch the rollout:**

```bash
oc get proxy/cluster -o jsonpath='{.status}{"\n"}'     # httpProxy/httpsProxy appear once readiness passed
watch oc get mcp                                        # UPDATING=True, then UPDATED=True for every pool
oc get nodes
oc get co | awk 'NR==1 || $3!="True" || $4!="False" || $5!="False"'
```

The node-level settings land in `/etc/mco/proxy.env` (the file the earlier research found in the MCO
code; Red Hat's docs don't name it):

```bash
oc debug $NODE -- chroot /host cat /etc/mco/proxy.env
```

**Rollback:** `oc patch proxy/cluster --type json -p '[{"op":"replace","path":"/spec","value":{}}]'`
("The `cluster` Proxy object cannot be deleted"; the docs say to set `spec: {}`). That is another
drain and reboot of every node. Changing `httpProxy`, `httpsProxy` or `noProxy` later reboots the
nodes again; a `trustedCA`-only change restarts CRI-O.

## Phase 5 (optional): keep workloads off the proxy

**Our guarantee does not depend on this phase.** Red Hat: "The system-wide proxy affects system
components only, not user workloads"
([`enable-cluster-wide-proxy.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/networking/configuring_network_settings/enable-cluster-wide-proxy.adoc)).
The platform never writes proxy variables into an application pod. Application teams are already
allowed to set a proxy in their own deployments; when they do, it is their deliberate choice under
our existing policy, not something the Proxy object does. So this is not a platform gap.

| Layer | Control | What it covers |
|---|---|---|
| Proxy settings | `proxy/cluster` sets proxy variables on platform components and OLM operators only | Application pods get no proxy from the platform (the guarantee) |
| Image policy | `allowedRegistries` (phase 3) | A workload pulling arbitrary `quay.io` images: CRI-O pulls through the node proxy for every pod; "Registries not in your allowlist are blocked" ([`images-configuration-allowed.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/images-configuration-allowed.adoc)) |
| Network (optional, this phase) | EgressFirewall denying the proxy's IPs | Only if security wants the platform proxy unusable by any pod |

**Do not apply this phase as written if application teams use the same proxy today:** the
EgressFirewall would cut them off. Prefer a separate proxy listener (or port) for the clusters'
nodes, with its own allowlist of Red Hat hosts, as phase 0 suggests. Then application traffic and
platform traffic are separated at the proxy, and nothing changes for the teams. Use the
EgressFirewall below only for namespaces that must not use any proxy, and leave out every namespace
whose team uses one.

**EgressFirewall per workload namespace (optional).** It must be named `default`; there can be only one per
namespace; it "does not apply to the host network namespace", so CRI-O and kubelet are unaffected.

```yaml
# egressfirewall-deny-proxy.yaml
apiVersion: k8s.ovn.org/v1
kind: EgressFirewall
metadata:
  name: default
spec:
  egress:
  - type: Deny
    to:
      cidrSelector: 10.20.0.15/32      # each proxy IP, including the VIP and every node of an HA proxy
```

Apply it to the namespaces security names, skipping any whose team uses the proxy:

```bash
for ns in $(oc get ns -o name | cut -d/ -f2 | grep -vE '^(openshift|kube-|default$)'); do
  if oc get egressfirewall default -n "$ns" >/dev/null 2>&1; then
    echo "SKIP $ns: already has an EgressFirewall, add the proxy rule to it by hand"
  else
    oc apply -n "$ns" -f egressfirewall-deny-proxy.yaml
  fi
done
```

- **Namespaces holding OLM operators** that must reach Red Hat through the proxy (rare; most get
  their images through CRI-O, not by themselves): leave them out of the loop and list them in the
  security sign-off.
- **New namespaces:** add the EgressFirewall to the project request template so `oc new-project`
  creates it:

  ```bash
  oc adm create-bootstrap-project-template -o yaml > /dev/shm/template.yaml
  # add the EgressFirewall above (namespace: ${PROJECT_NAME}) under .objects, then:
  oc create -f /dev/shm/template.yaml -n openshift-config
  oc patch project.config.openshift.io/cluster --type merge -p '{"spec":{"projectRequestTemplate":{"name":"project-request"}}}'
  ```

  The template does not run for namespaces created with `oc create namespace` or by Argo CD. Put the
  EgressFirewall in those namespaces' Git manifests.
- **Cluster-wide alternative (not verified for 4.18):** an `AdminNetworkPolicy` that denies egress
  to the proxy from every namespace without the `openshift-` prefix would replace the per-namespace
  objects. Check that our version supports egress `networks` peers before relying on it.

## Phase 6: update checks from Red Hat

```bash
oc get clusterversion version -o jsonpath='{.spec.upstream}{"\n"}'   # today: our local OSUS
oc patch clusterversion version --type json -p '[{"op":"remove","path":"/spec/upstream"}]'
oc get clusterversion version -o jsonpath='{.spec.channel}{"\n"}'    # stays eus-4.18
oc adm upgrade                                                       # lists recommended updates from api.openshift.com
oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="RetrievedUpdates")]}{"\n"}'
```

"The default value for `upstream` is `https://api.openshift.com/api/upgrades_info/v1/graph`"
(`modules/update-changing-update-server-cli.adoc`); removing the field returns to it. `RetrievedUpdates`
must be `True`. If it is `False`, the message names the error; it is usually `api.openshift.com`
missing from the proxy allowlist or a CA problem.

The signature ConfigMaps that Step 1 applied (`mirrored-release-signatures` in
`openshift-config-managed`) can stay. The CVO now also reaches `mirror.openshift.com`.

## Phase 7: operator catalogs from Red Hat

Today's Subscriptions point at the mirrored CatalogSources (`cs-redhat-operator-index-…`). Turn on
the default Red Hat source only, move each Subscription to it, then delete the mirrored source in
phase 9.

```bash
oc patch operatorhub cluster --type merge -p '{"spec":{"disableAllDefaultSources":true,"sources":[{"name":"redhat-operators","disabled":false}]}}'
oc get catalogsource -n openshift-marketplace
oc get packagemanifests -l catalog=redhat-operators | head    # wait until it lists packages
```

The docs describe `disableAllDefaultSources` as "an override that controls availability of all
default catalogs" and say the resource can "enable or disable the default catalogs". No doc gives
this exact patch; check the result with `oc get catalogsource` and adjust.

Move each Subscription (repeat per operator; keep its channel):

```bash
oc get subscriptions.operators.coreos.com -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SOURCE:.spec.source,CHANNEL:.spec.channel,APPROVAL:.spec.installPlanApproval
oc patch subscription.operators.coreos.com <name> -n <ns> --type merge \
  -p '{"spec":{"source":"redhat-operators","sourceNamespace":"openshift-marketplace"}}'
oc get subscription.operators.coreos.com <name> -n <ns> -o jsonpath='{.status.state}{"\n"}'
```

- Set `installPlanApproval: Manual` first if it isn't. The stock catalog may hold newer versions than
  our mirror, and an `Automatic` subscription would update on the spot.
- `ResolutionFailed` means the installed version is not in the stock catalog's channel; leave that
  Subscription on the mirrored source and raise it.
- **Catalog model (D2):** the team may keep a filtered catalog (model A) in our registry instead of
  the stock catalog. Then keep the mirrored CatalogSource, skip this phase and keep the registry for
  that one image. See [`DESIGN-DECISIONS.md`](../DESIGN-DECISIONS.md), D2, and
  [`catalog-policies/`](../catalog-policies/).
- Partner operators (the IBM Fusion sample in Step 1) need `certified-operators` turned on the same
  way, and `registry.connect.redhat.com` on the allowlist.

## Phase 8: the first connected update

Run one update with the mirror still in place: a z-stream, or the planned EUS update to 4.20 as in
the release guide, without the mirroring steps.

```bash
oc adm upgrade channel eus-4.20                 # only when moving to 4.20
oc adm upgrade --to-latest                      # or --to=<version> from the recommended list
oc adm upgrade                                  # progress
```

- The oc-mirror IDMS objects don't use `NeverContactSource`, so CRI-O tries the mirror first and
  falls back to `quay.io` for anything the mirror lacks. A release we never mirrored can be pulled
  this way, which tests the proxy path. Confirm with
  `oc debug $NODE -- chroot /host cat /etc/containers/registries.conf`.
- **4.20 to 4.21 (sigstore):** the default `openshift` ClusterImagePolicy is "active by default"
  from 4.21. On a connected cluster CRI-O reads the `.sig` signatures from `quay.io` itself; the
  docs' requirement to mirror them applies while a mirror for `ocp-release` and `ocp-v4.0-art-dev`
  is configured. The admin acknowledgment `ack-4.20-sigstore-in-4.21` (4.20
  `modules/update-preparing-ack-sigstore.adoc`) states that signatures are mirrored. Our reading:
  if the gate appears, remove the mirror sets (phase 9) first, then give it.
- **4.21 to 4.22:** update to at least 4.22.16; earlier 4.22 builds failed on workers with old boot
  images with "A signature was required, but no signature exists" (OCPBUGS-122961).

## Phase 9: remove the mirror (maintenance window)

Only after phase 8 succeeded.

```bash
oc get imagedigestmirrorset,imagetagmirrorset,imagecontentsourcepolicy
oc delete imagedigestmirrorset <names>
oc delete imagetagmirrorset <names>
oc delete imagecontentsourcepolicy <names>     # if any remain from older oc-mirror runs
watch oc get mcp
```

- **Node effect:** "If you delete an ITMS, IDMS, or ICSP CR object, the MCO drains and reboots the
  node" (`modules/images-configuration-registry-mirror.adoc`). Another part of the same page, and the
  MCO code, say drain and CRI-O reload. Plan for a reboot; it is a question for Red Hat Support.
- **Then remove what served the mirror:**

  ```bash
  oc delete catalogsource <mirrored names> -n openshift-marketplace   # only those no Subscription uses
  oc delete updateservice --all -n openshift-update-service           # the local OSUS, once no other cluster's upstream points at it
  # uninstall the cincinnati-operator Subscription and CSV in openshift-update-service
  ```

- **Tidy the trust and policy:** drop the mirror's entry from `allowedRegistries`, the mirror's key
  from the `additionalTrustedCA` ConfigMap (and `updateservice-registry`), and the mirror's login
  from the pull secret (repeat the phase 2 commands with
  `jq 'del(.auths["registry-dc1.example.com:8443"])'`). Keep the mirror registries themselves until every
  cluster has gone through this runbook.
- **Check a node again:** `registries.conf` should list no mirrors for `quay.io` or
  `registry.redhat.io`.

## Verify: only core components reach Red Hat

Run these after phase 6 and again after phase 9; keep the output as evidence for security.

| # | Test | Command | Expected |
|---|---|---|---|
| 1 | Proxy applied | `oc get proxy/cluster -o jsonpath='{.status}'` | `httpProxy`, `httpsProxy` and the full `noProxy` |
| 2 | Update checks work | `oc adm upgrade` | Recommended updates listed, no `RetrievedUpdates=False` |
| 3 | CRI-O pulls from Red Hat | `oc debug $NODE -- chroot /host crictl pull registry.redhat.io/ubi9/ubi-minimal:latest` | Pulled |
| 4 | Node has no direct route | `oc debug $NODE -- chroot /host curl -s -m 10 --noproxy '*' https://quay.io` | Times out |
| 5 | Proxy allowlist holds | `oc debug $NODE -- chroot /host sh -c '. /etc/mco/proxy.env; curl -s -m 10 -o /dev/null -w "%{http_code}" -x $HTTPS_PROXY https://www.example.com'` | Denied (`403` or connection refused) |
| 6 | A workload pod gets no proxy | in a test namespace: `oc run t --image=registry.redhat.io/ubi9/ubi-minimal --restart=Never -- sleep 600`, then `oc exec t -- env \| grep -i proxy` | Nothing |
| 7 | Optional, only with phase 5: a workload pod cannot use the platform proxy | `oc exec t -- curl -s -m 10 -x http://proxy.example.com:3128 https://quay.io` | Times out (EgressFirewall); skip if phase 5 was not applied |
| 8 | A workload pod cannot go direct | `oc exec t -- curl -s -m 10 https://quay.io` | Times out (firewall) |
| 9 | Pulls outside the allowlist fail | `oc run t2 --image=quay.io/libpod/alpine:latest --restart=Never -- true; oc get pod t2` | `ErrImagePull`, "not allowed" in `oc describe` |
| 10 | Platform still healthy | `oc get co` | All `Available=True`, none `Degraded` |
| 11 | Proxy logs | Ask the network team for a week of the clusters' requests | Sources are node IPs only; destinations are on the allowlist; denies reviewed |

Tests 6 to 9 need a namespace created the way users create them, with no proxy set by us. Test 6
is the guarantee: the platform injects nothing.
Clean up with `oc delete pod t t2`.

Red Hat documents tests 1, 2 and 10 (`modules/nw-verify-proxy-configuration.adoc`; its CVO log
command reuses the MCO's pod label and won't find the CVO pod, use
`oc logs -n openshift-cluster-version deployment/cluster-version-operator`). Tests 3 to 9 and 11 are
our own.

## Still open

- **Security:** approval of the host list, node egress through the proxy, and D3 (telemetry).
- **Red Hat Support case:**
  - TLS interception (D4).
  - Whether updates need `console.redhat.com`/`sso.redhat.com`, and whether on-prem clusters need
    `quayio-production-s3.s3.amazonaws.com`.
  - Whether `allowedRegistries: quay.io/openshift-release-dev` is enough.
  - Whether deleting an IDMS reboots or only drains.
  - Whether changing an existing proxy reboots the same way as enabling it (the docs describe only
    enabling).
- **Our team:** the internal-service inventory for `noProxy` per cluster; which namespaces, if any,
  need the proxy for an operator; catalog model D2.

## Sources

Read from [`openshift/openshift-docs`](https://github.com/openshift/openshift-docs) on 2026-10-07
(branch `enterprise-4.18` unless noted; "same in 4.22" where checked):

- Proxy: `networking/configuring_network_settings/enable-cluster-wide-proxy.adoc`,
  `modules/nw-proxy-configure-object.adoc` (same in 4.22), `modules/nw-proxy-remove.adoc`,
  `modules/nw-verify-proxy-configuration.adoc`, `security/certificate_types_descriptions/proxy-certificates.adoc`,
  `modules/olm-overriding-proxy-settings.adoc`, `modules/cluster-wide-proxy-preqs.adoc`
- Firewall: `installing/install_config/configuring-firewall.adoc` with `modules/configuring-firewall.adoc`
  (4.22: `modules/configuring-firewall-module.adoc`, same hosts)
- Pull secret and telemetry: `modules/images-update-global-pull-secret.adoc`, `snippets/node-icsp-no-drain.adoc`
  (same in 4.22), `modules/enabling-remote-health-reporting.adoc`, `modules/insights-operator-new-pull-secret-enable.adoc`
- Mirror removal and image policy: `disconnected/connected-to-disconnected.adoc`,
  `modules/connected-to-disconnected-restore.adoc`, `modules/images-configuration-registry-mirror.adoc`
  (same in 4.22), `snippets/allowed-registries-warning.adoc`, `modules/images-configuration-blocked-payload.adoc`
- Update server and catalogs: `modules/update-changing-update-server-cli.adoc`,
  `modules/olm-operatorhub-architecture.adoc`, `modules/olm-restricted-networks-configuring-operatorhub.adoc`
- EgressFirewall: `modules/nw-egress-firewall-about.adoc`
- Sigstore: 4.21 `modules/rn-ocp-release-notes-new-features.adoc`, 4.22
  `modules/nodes-sigstore-configure-cluster-policy.adoc`, 4.20 `modules/update-preparing-ack-sigstore.adoc`,
  4.22 `modules/zstream-4-22-16.adoc`
- Earlier research (2026-09-25): [`openshift-update-egress.html`](../openshift-update-egress.html) for
  the DNS conditions, node effects and security controls

## Diagram sources

The figure is drawn in [`../diagrams/three-steps/source.html`](../diagrams/three-steps/source.html) and rendered with
[diagram-kit](https://github.com/ephico2real2/diagram-kit); the render command is in
[`../SOLUTIONS.md`](../SOLUTIONS.md), Diagram sources. The figure, the text beside it and the page change together.
