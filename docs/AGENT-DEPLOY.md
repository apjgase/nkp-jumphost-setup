# Deploying an NKP lab with nkp-jumphost-setup: instructions for an agent

You are deploying an NKP 2.19 lab for the user: a management cluster built from the dark site bundle, Harbor on it with the bundle pushed in, and a first workload cluster that pulls from that Harbor. You do it by driving `nkp-jumphost-setup.sh` on a Linux jump host over SSH. You do not change the script; if it misbehaves, collect the evidence and report it (the project background is in [PROJECT-REVIEW.md](PROJECT-REVIEW.md)).

## Rules

1. **Ask before anything destructive or hard to undo.** That means: starting the deployment (it changes the subnet's IP pool and DHCP options and creates VMs), `--destroy`, `nkp delete ...`, deleting VMs, files or directories, and changing anything in Prism Central yourself. Show what will happen and wait for an explicit yes. Read-only commands, downloads, `--prereqs-only`, `--check` and `--status` need no approval.
2. **Passwords come from the user in chat, when needed, and go nowhere else.** Never write them to a file (local or remote), never put them on a remote command line, never echo them back, never include them in a summary. Pass them over SSH standard input, as shown below. Ask again if you need one later rather than storing it.
3. **Never guess lab values.** Prism Central address, cluster and subnet names, sizes: take them from the user or from `--check` output, and confirm.
4. **Do not rerun a failed deployment.** A rerun tries to create the cluster again. Diagnose first (section 9), then ask.
5. **Treat the bundle download link as sensitive.** Portal links often carry a signed token: use it once in the download command, do not repeat it or write it anywhere else.
6. Keep the user informed at milestones (bundle ready, prerequisites done, check passed, management cluster up, Harbor pushed, workload up), briefly.

## 1. Ask the user for

- The SSH target of the jump host (`user@host`, and port or key if not default). Root, or a user with sudo.
- Prism Central address and user name (default `admin`). The password later, in chat, when you reach `--check`.
- The Prism Element cluster name, if Prism Central manages more than one, and the subnet name, if it is not `primary` or `primary-<cluster>`.
- Whether to build both clusters (default) or only the management cluster.
- Whether a registry already exists that should be used instead of deploying Harbor (`REGISTRY_MIRROR_URL`). Usually not.

In the commands below, `H` is the SSH target, for example `H=root@jumphost`.

## 2. Check SSH access

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 "$H" 'cat /etc/os-release | head -2; id -un; nproc; free -g | head -2; df -h ~ /var/lib'
```

If this asks for a password or fails, stop and ask the user to set up key access for you (do not take an SSH password). The jump host should be Linux with cgroups v2 (Rocky Linux / RHEL 9 is tested), at least 4 CPUs and 4 GiB of free memory for the bootstrap cluster, and enough disk: about twice the bundle size in the home filesystem (archive plus unpacked copy) and 30 GiB more than the bundle in `/var/lib`.

## 3. Get the script

```bash
ssh "$H" 'cd ~ && curl -fsSL https://github.com/apjgase/nkp-jumphost-setup/archive/refs/heads/main.tar.gz | tar -xzf - && ls nkp-jumphost-setup-main'
```

Run the same command again later to update the script; it keeps `nkp-lab.env`.

## 4. The NKP bundle

The script needs the NKP 2.19 air-gapped bundle, `nkp-air-gapped-bundle_v2.19.x_linux_amd64.tar.gz` (about 37 GB; an `nkp-bundle_v2.19.x_linux_amd64.tar.gz` also works). It looks for the archive in the home directory, `~/Downloads` or the current directory, and for an unpacked copy under `~/nkp-dist` or `~`.

```bash
ssh "$H" 'ls -l ~/nkp*2.19*linux_amd64.tar.gz ~/Downloads/nkp*2.19*linux_amd64.tar.gz 2>/dev/null; ls -d ~/nkp-dist/*/nkp-v2.19*/container-images ~/nkp-v2.19*/container-images 2>/dev/null'
```

If nothing is found, ask the user:

> The NKP 2.19 air-gapped bundle (nkp-air-gapped-bundle_v2.19.x_linux_amd64.tar.gz, about 37 GB) is not on the jump host. Can you send me a download link for it, and its SHA-256 checksum if you have one? I will download it directly on the jump host.

Download it on the jump host in the background, keeping the file name from the link:

```bash
ssh "$H" 'cd ~ && nohup curl -fL --retry 5 --retry-delay 15 -C - -o nkp-air-gapped-bundle_v2.19.0_linux_amd64.tar.gz '\''<LINK>'\'' >~/bundle-download.log 2>&1 </dev/null & echo started'
```

Check progress every few minutes with `ssh "$H" 'ls -l ~/nkp*2.19*.tar.gz; tail -c 200 ~/bundle-download.log; pgrep -f "curl -fL" >/dev/null && echo downloading || echo finished'`. If it stops early, the same command resumes it (`-C -`). When done, verify it: `sha256sum` against the user's checksum if you have one, otherwise at least `tar -tzf <file> | head -5`. If the link has expired (HTTP 403), ask the user for a new one.

## 5. Prerequisites

Installs Docker, kubectl, the nkp CLI and tmux, and unpacks the bundle into `~/nkp-dist`. Takes 5 to 20 minutes, mostly unpacking.

```bash
ssh "$H" 'cd ~/nkp-jumphost-setup-main && nohup ./nkp-jumphost-setup.sh --prereqs-only --unattended >~/nkp-prereqs.log 2>&1 </dev/null & echo started'
ssh "$H" 'pgrep -f "nkp-jumphost-setup.sh --prereqs-only" >/dev/null && echo RUNNING || echo DONE; tail -n 15 ~/nkp-prereqs.log'
```

Run it once. Every later command uses `--skip-prereqs` (otherwise the bundle is unpacked again). An `ERROR:` line in the log means it failed: report the last 30 lines to the user.

## 6. The answers file

Create the template, then fill in what the user told you. Blank values are discovered from Prism Central.

```bash
ssh "$H" 'cd ~/nkp-jumphost-setup-main && ./nkp-jumphost-setup.sh --init-config --unattended'
ssh "$H" 'cd ~/nkp-jumphost-setup-main && sed -i \
  -e "s|^NUTANIX_ENDPOINT=.*|NUTANIX_ENDPOINT=https://<PC address>:9440|" \
  -e "s|^NUTANIX_USER=.*|NUTANIX_USER=admin|" \
  -e "s|^SIZING=.*|SIZING=pro|" -e "s|^WL_SIZING=.*|WL_SIZING=pro|" nkp-lab.env && grep -vE "^#|^$" nkp-lab.env'
```

Also set `NUTANIX_CLUSTER=` and `SUBNET=` when the user gave them. Keep `SIZING=pro`: the Starter size is too small for a management cluster (Kommander times out). Use Pro for the workload cluster too unless `--check` shows the capacity is short; then ask the user. Never put a password in this file.

## 7. Check the lab (read-only)

Ask the user for the Prism Central password now, then:

```bash
printf '%s\n' '<PC PASSWORD>' | ssh "$H" 'IFS= read -r NUTANIX_PASSWORD; export NUTANIX_PASSWORD; cd ~/nkp-jumphost-setup-main && ./nkp-jumphost-setup.sh --check --unattended --config nkp-lab.env'
```

It prints one line per check (PASS, WARN, FAIL, SKIP), writes `~/nkp/lab-check.txt`, and exits 1 if anything failed. It changes nothing. Fix every FAIL before going on:

| FAIL | What to do |
| --- | --- |
| Docker, kubectl or nkp CLI missing | Section 5 did not finish; check its log |
| Bundle not found or not unpacked | Section 4 or 5 |
| Login | Wrong password or user: ask the user again |
| Subnet not found | Set `SUBNET=` to the name the check suggests, after confirming with the user |
| Prism Element / Node image / Storage container | Several choices or none: set `NUTANIX_CLUSTER`, `VM_IMAGE` or `STORAGE_CONTAINER_NAME` from the names in the output, after confirming. The node image must be an NKP Rocky image for Kubernetes 1.36 in Prism Central; if there is none, ask the user |
| IP plan | The subnet's IPAM pool has no free block of 12 or more addresses; ask the user |
| Management sizing | Set `SIZING=pro` |
| Memory, vCPU, Storage | Not enough capacity: tell the user the numbers and ask |

Acceptable warnings: an untrusted Prism Central certificate (the script uses insecure mode), the lab DNS server not resolving from the jump host, a missing SSH key (the script creates one), Storage counted as thin-provisioned.

## 8. Get approval, then deploy

Show the user, from the check output: the address block that will be reserved and what each part is for (management API address, workload API address, two load balancer ranges); that the subnet's IPAM pool shrinks by that block and its DHCP DNS points at the lab DNS server; the node count and size of each cluster; capacity; the bundle; and the duration (2 to 3 hours: management cluster about an hour, Harbor and the push, then the workload cluster). Ask for a clear go-ahead. Do not start without it: under `--unattended` the script applies the subnet change and creates the VMs without asking.

```bash
printf '%s\n' '<PC PASSWORD>' | ssh "$H" 'IFS= read -r NUTANIX_PASSWORD; export NUTANIX_PASSWORD; mkdir -p ~/nkp && cd ~/nkp-jumphost-setup-main && nohup ./nkp-jumphost-setup.sh --lab --skip-prereqs --unattended --config nkp-lab.env >~/nkp/agent-lab.log 2>&1 </dev/null & echo started'
```

For the management cluster only, use `--skip-prereqs --unattended --config nkp-lab.env` without `--lab`.

Monitor every 5 to 10 minutes, not continuously:

```bash
ssh "$H" 'pgrep -f "nkp-jumphost-setup.sh" >/dev/null && echo RUNNING || echo DONE; tail -n 25 ~/nkp/agent-lab.log'
```

Lines starting with `==>` are steps; `✔` is done, `!` a warning, `ERROR:` a failure. Under `--unattended` the script may add up to two workers by itself when platform apps cannot be scheduled; that is expected. When the run is done and the log ends without `ERROR:`, read `~/nkp/lab-summary.txt` and give the user the dashboard URL, the Harbor URL, the kubeconfig paths and the main commands. The file also holds the dashboard password: tell the user where it is, and only paste it if they ask.

## 9. When something fails

Do not rerun. Collect and report:

```bash
ssh "$H" 'tail -n 80 ~/nkp/agent-lab.log; ls -t ~/nkp/*/create-cluster-*.log | head -1'
ssh "$H" 'cd ~/nkp-jumphost-setup-main && ./nkp-jumphost-setup.sh --status --unattended'
```

The script's last lines usually name the situation and the next commands. Common cases:

| Log shows | Meaning | Next step |
| --- | --- | --- |
| `Waiting for cluster control-planes to be ready` timed out; "objects are still on the local bootstrap cluster" | The management cluster never became reachable | Run the inspection commands the script printed (`nkp describe cluster ... --kubeconfig ~/.kube/config`, `kubectl ... get kubeadmcontrolplane,machines,nutanixmachines`, the `capx-system` logs). Report them. This is an open issue; the cluster may still recover by itself, so look again after 10 to 15 minutes before suggesting `--destroy` |
| `timed out waiting for KommanderInitialized`, or "no platform applications" | Kommander did not install, usually undersized nodes | Report node sizes (`kubectl top nodes` with the cluster kubeconfig). Fix is usually destroy and redeploy with Pro sizing: ask |
| HelmReleases not ready after the remediation | Some platform apps stuck | Report `--status`; apps often recover; check again later |
| Harbor or push step failed, management cluster fine | | Report; rerunning `--harbor --skip-prereqs --unattended` (with the password, under nohup) is safe and needs no approval. It skips a running Harbor, and under `--unattended` it also skips the push when the project already holds images; if a push was cut short, tell the user, who can rerun `--harbor` interactively and answer yes to push again |
| Workload cluster failed | | Report `--status`; do not create it again; ask |

To tear down, after the user approves:

```bash
printf '%s\n' '<PC PASSWORD>' | ssh "$H" 'IFS= read -r NUTANIX_PASSWORD; export NUTANIX_PASSWORD NKP_DESTROY_CONFIRM=<management cluster name>; cd ~/nkp-jumphost-setup-main && nohup ./nkp-jumphost-setup.sh --destroy --unattended >~/nkp/agent-destroy.log 2>&1 </dev/null & echo started'
```

It deletes the workload clusters and the management cluster (also one still held by the bootstrap cluster), restores the subnet, and archives the answers to `~/nkp/archive-<date>/`. If it reports that the cluster is unreachable and no bootstrap cluster holds it, it stops without restoring the subnet: ask the user, who can run `--destroy` interactively to restore the subnet anyway. A subnet restore failure is retried by the script; if it still fails, rerunning `--destroy` is safe.

After a destroy, a new deployment starts again at section 7.
