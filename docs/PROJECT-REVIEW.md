# nkp-jumphost-setup: project review

This is the reference for anyone continuing this project: the owner, the team, and AI agents that develop the script further. It covers what the project does, how it is built, every significant decision and why it was made, what happened on real labs, how it is tested, and what is still open. The instructions for an agent that only *runs* a deployment are in [AGENT-DEPLOY.md](AGENT-DEPLOY.md).

## 1. Purpose

One script that takes a freshly provisioned Nutanix lab (Prism Central, one AHV Prism Element cluster, a primary subnet with IPAM) and a Linux jump host, and builds a complete NKP 2.19 lab on it:

1. Install the jump host prerequisites (Docker, kubectl, nkp CLI, tmux).
2. Reserve IP addresses for NKP from the subnet's IPAM pool.
3. Create a self-managed **management cluster** from the dark site (air-gapped) bundle.
4. Deploy **Harbor** on that cluster as the NKP guide describes, and push the bundle images into it.
5. Create the first **workload cluster**, pulling every image from that Harbor instead of the internet.
6. Tear it all down again (`--destroy`) and give the IP addresses back to the subnet.

The owner's requirements, in their own words, were: deploy NKP from the dark site bundle as documented; deploy Harbor; push the images to Harbor; use that registry for all later clusters; and use shell only where required, doing the external API work (Prism Central, Kubernetes, Harbor) in Python.

## 2. Status (2026-10-30)

| Area | State |
| --- | --- |
| Jump host prerequisites | Works on a real lab (Rocky Linux 9) |
| `--check` (read-only readiness test) | Works on a real lab |
| IP plan, AutoAD DNS on the subnet | Works on a real lab |
| Management cluster from the bundle | Works on a real lab with Pro sizing (Kommander + GitClaim + platform apps) |
| Harbor deployment and `nkp push bundle` | Works on a real lab (Rook Ceph + kube-prometheus-stack enabled first; full 447-image push) |
| Workload cluster through Harbor | Works on a real lab (robot pull from Harbor; CAPI wait uses `Available` / `Provisioned`) |
| End-to-end `--lab` (mgmt + Harbor + workload) | Two consecutive real-lab successes after the 10-29/10-30 fixes (destroy between rounds) |
| LoadBalancer smoke test on workload | Verified: Deployment + `type: LoadBalancer` received an EXTERNAL-IP and answered HTTP |
| `--destroy` and subnet restore | Works on a real lab (after the retry fix for a Prism Central timestamp conflict) |
| Offline tests | `tests/run-all.sh`: all pass |

## 3. Repository layout

| Path | What it is |
| --- | --- |
| `nkp-jumphost-setup.sh` | The entry point. Bash. Prerequisites, prompts and answers, the nkp CLI calls, phase orchestration, status and summary output |
| `nkp_lab.py` | Companion helper, Python 3.9, standard library only. Every Prism Central, Kubernetes (through `kubectl`) and Harbor API call |
| `test_nkp_lab.py` | `unittest` suite for `nkp_lab.py`, with a fake Prism Central and Harbor HTTP server |
| `tests/run-all.sh` | One command that runs every offline test |
| `tests/mock.sh` | Shell functions with `nkp`, `kubectl`, `py` and Prism Central mocked |
| `tests/integration.sh` | The shell script driving the real `nkp_lab.py` against the fake servers over TLS, with a `kubectl` stub |
| `tests/lab-e2e.sh` | A full `--lab --unattended` run, then the workload child run, against the same fakes |
| `tests/fake/` | The fake server (`fakeserver.py`, reusing the handler in `test_nkp_lab.py`) and stubs for `kubectl` and `ping` |
| `tests/lib.sh` | Shared test setup: repo paths, scratch directory, a fresh TLS certificate per run, portable `sed`/`stat` |
| `docs/` | This review and the deployment-agent instructions |
| `README.md`, `LICENSE` | User quickstart, modes, secrets and lab assumptions; MIT license |
| `.github/workflows/unittest.yml` | CI: `python3 -m unittest test_nkp_lab` in a Rocky Linux 9 container (its system Python 3.9, as on the jump hosts) and on Python 3.13, on every push to `main` and every pull request |

Users get the code with:

```bash
curl -fsSL https://github.com/apjgase/nkp-jumphost-setup/archive/refs/heads/main.tar.gz | tar -xzf - && cd nkp-jumphost-setup-main
```

## 4. Architecture

### Shell and Python split

The shell script keeps what has to be shell: package installation, the interactive questions, `nkp` CLI calls, tmux, and the flow between phases. Everything that talks to an API is a subcommand of `nkp_lab.py`:

| Group | Commands |
| --- | --- |
| `ip` | address arithmetic used by the IP plan |
| `tls` | `fetch`, `probe` (0 trusted, 1 untrusted, 2 unreachable), `covers` |
| `dns` | `answers` (does the lab DNS server resolve the domain) |
| `pc` | `status`, `clusters`, `subnets`, `images`, `containers`, `ntp`, `ip-plan`, `subnet-pools`, `subnet-set`, `capacity` |
| `k8s` | `clusters`, `reserved-ranges`, `kubelet-version`, `workspaces`, `workspace-create`, `hr-not-ready`, `starved-pods`, `md0`, `hr-reconcile`, `ncr`, `harbor-password`, `uid`, `harbor-prereqs`, `harbor-deploy` |
| `harbor` | `ping`, `whoami`, `ensure-project`, `public`, `repos`, `robot` |

The interface between the two is deliberately narrow:

- **Secrets go through the environment only**: `NKP_PC_ENDPOINT`, `NKP_PC_USER`, `NKP_PC_PASSWORD`, `NKP_PC_TLS`, `NKP_HARBOR_URL`, `NKP_HARBOR_CA`, `NKP_HARBOR_USER`, `NKP_HARBOR_PASSWORD`. They never appear on a command line. The shell wrappers `py` and `hpy` set them.
- **Results come back as `KEY=value` lines** on stdout, which the shell's `py_vars` turns into variables (keys must match `^[A-Z_][A-Z0-9_]*$`), or as plain text or tab-separated lines.
- **Booleans are exit codes**: for example `pc ip-plan` exits 3 (no IPAM pool), 4 (no free block) or 5 (only blocks with addresses answering ping).
- Messages for the user go to stderr.

### Shell conventions

- `set -Eeuo pipefail` with an ERR trap that reports the failing line. Any command that is allowed to fail must sit in an `if`, `||` or `&&` context, otherwise it aborts the run.
- Questions go through `ask`, `ask_yn`, `ask_secret` and `pick`. Under `--unattended` they take the default, or stop when there is none or it is invalid. This is what makes `--lab` and the agent runs possible.
- Long runs relaunch inside a tmux session named `nkp` when started from a terminal. Without a terminal (SSH command, nohup) they continue in place.

### Phases and options

| Option | What it does |
| --- | --- |
| (none) | Prerequisites, then the interactive management cluster setup |
| `--prereqs-only` / `--skip-prereqs` | Only phase 1 / skip phase 1 |
| `--check` | Read-only readiness test of the jump host, bundle, Prism Central, IP plan (dry run), DNS, capacity, registry and an existing management cluster. Report in `~/nkp/lab-check.txt`, exit 1 on any failure |
| `--lab` | All questions up front, then the management cluster, Harbor and push, and the first workload cluster unattended |
| `--harbor` | Deploy Harbor on the existing management cluster if missing, and push the bundle (skipped when already pushed) |
| `--workload` | Create another workload cluster on the existing management cluster |
| `--status` | What is not ready on a cluster the script created |
| `--destroy` | Delete the workload clusters and the management cluster, restore the subnet's IPAM pool and DHCP options, archive the answers |
| `--config FILE`, `--init-config`, `--unattended` | Answers file (template from `--init-config`), and never prompting |
| `--package`, `--bundle-dir`, `--workdir`, `--print-only`, `--insecure`, `--no-ip-plan` | Inputs and behaviour switches; see `--help` |

### What `--lab` does, in order

1. Asks every question for both clusters (or takes them from `--config`), discovering Prism Element, subnet, image, container and NTP from Prism Central.
2. Plans the IP addresses: takes a block of at most 30 and at least 12 addresses from the tail of the subnet's IPAM pool, keeping 20 pool addresses for node VMs, and skipping addresses used by VMs or answering ping. The block holds the management API address, the workload API address and two load balancer ranges.
3. Shows the plan and capacity, then shrinks the IPAM pool and points the subnet's DHCP DNS at the lab DNS server VM (`autoad`, domain `ntnxlab.local`). The original settings are saved in `~/nkp/nkp-ip-plan.env` for `--destroy`.
4. Runs the NKP preflight, then `nkp create cluster nutanix --self-managed --bundle <bundle files>`. This creates the cluster and its internal registry mirror from the bundle.
5. Deploys Harbor in `ncr-system`: enables CloudNativePG, raises Rook Ceph from 4 to 8 volumes of 40 GiB, creates an object bucket claim on `dkp-object-store`, writes the S3 credentials secret and the Harbor overrides ConfigMap, and creates the Harbor AppDeployment.
6. Creates project `nkp` in Harbor and runs `nkp push bundle` with every bundle file (including the catalog bundles) to `https://<ingress address>:5000/nkp`.
7. Starts a child run with `--workload --unattended` that creates the workload cluster with `--registry-mirror-url` pointing at that Harbor, and a pull-only robot account for it.
8. Writes `~/nkp/lab-summary.txt` (mode 600: it holds the dashboard login).

### Files on the jump host (`~/nkp`)

| File | Content |
| --- | --- |
| `nkp-install.env`, `nkp-workload.env` | Saved answers (never passwords) |
| `nkp-ip-plan.env` | IP plan and the subnet's original pool and DHCP options |
| `lab-check.txt`, `lab-summary.txt` | `--check` report; final summary (600) |
| `<cluster>/<cluster>.conf` | Kubeconfig |
| `<cluster>/create-cluster-*.log`, `create-cluster.cmd`, `preflight.log`, `cluster-dryrun.yaml` | Logs, the exact command with passwords masked, the preflight manifest (600, contains credentials) |
| `<cluster>/harbor-push.env`, `harbor-ca.pem` | Push record (no secrets) and the Harbor CA |
| `archive-<date>/` | What `--destroy` moved away |

The NKP package is unpacked to `~/nkp-dist/<package name>/`. The script finds the newest `nkp-v2.19.*/container-images` under `~/nkp-dist` or `~`, and an unpacked package in `.`, `~` or `~/Downloads`.

## 5. Decisions

In the order they were made. "Owner" means the decision was the owner's call; the others were proposed and accepted.

| Date | Decision | Why |
| --- | --- | --- |
| 10-19 | CLI installation, not the UI; one script that installs everything after the package is downloaded | Owner |
| 10-19 | Public GitHub repo `apjgase/nkp-jumphost-setup`, downloaded as a tarball | Owner wanted a direct link; the tarball keeps the files together |
| 10-20 | Docker pinned to 27.4.0; `docker-ce` and `docker-ce-cli` RPM versions resolved separately | The two packages carry different epochs, so one version string matched neither |
| 10-20 | Install tmux and relaunch the setup inside it | Cluster creation takes up to an hour and must survive an SSH drop |
| 10-24 | Ask for the Nutanix Portal registry token (user `svcregistrynkp`) and verify it with `docker login` | `nkp create cluster --self-managed` requires registry credentials unless air-gapped or a mirror is set |
| 10-24 | `--insecure` by default for an untrusted Prism Central certificate | The cluster's webhook failed calling the Prism Central v4 API on a lab certificate |
| 10-25 | `--status`; after a failure on an existing cluster, show what is not ready instead of suggesting a rerun | A rerun would try to create the cluster again |
| 10-25 | At least 4 workers, even for Starter; show node-pool commands with `-n kommander` | Two 4 vCPU workers left Kommander apps Pending; the management cluster's node pools live in `kommander` |
| 10-25 | `--workload` automation, with workspace selection and IP collision checks | Owner |
| 10-25 | Pin to NKP 2.19; IP plan from the IPAM pool's tail; AutoAD DNS via DHCP; `--config`/`--unattended`; capacity check; auto-remediation (add up to 2 workers when pods are unschedulable, retry failed HelmReleases); lab summary; `--destroy` that restores the subnet | Owner's "streamline the management and first workload cluster" brief |
| 10-25 | Seed from the air-gapped bundle with `--bundle`; Nutanix token optional with the bundle | Pulling from Docker Hub "takes ages" (owner) |
| 10-26 | Dark site flow as documented: management cluster from the bundle, then Harbor on it, push, all later clusters pull from Harbor | Owner's five-point brief (section 1) |
| 10-26 | Harbor on the management cluster the script creates, as in "Deploying Harbor on a Management Cluster"; Rook Ceph raised to 8 × 40 GiB through an AppDeployment override | The docs recommend about 100 GB for Harbor and say to extend Rook Ceph through an override, never the defaults ConfigMap. 4 more volumes add about 120 GiB usable |
| 10-26 | One pull-only robot account per workload cluster (`nkp-<cluster>`); anonymous pulls when the project is public; admin as last resort | Least privilege per cluster, and robots can be revoked one at a time |
| 10-26 | External registry alternative: `REGISTRY_MIRROR_URL` set means no Harbor deployment, push there instead | Labs that already have a registry |
| 10-26 | Push automatically, but skip when the push record matches the cluster UID, registry URL and bundles; ask (default No) when the project already holds images | A push of the full bundle takes a long time |
| 10-26 | Push every bundle, including the catalog bundles | Owner |
| 10-26 | API work in `nkp_lab.py`, standard library only, Python 3.9 | Owner asked for Python; stdlib avoids pip on dark site jump hosts; 3.9 is what Rocky 9 ships |
| 10-26 | Passwords never in answers files; secret files mode 600; passwords masked in displayed commands | Lab files get copied around |
| 10-26 | `--check`: read-only readiness test, one command | Owner wanted tests to run on a real lab before a deployment |
| 10-26 | `SUBNET` blank by default, matching `primary` or `primary-<Prism Element>`; case-only mismatches accepted with a warning | Real labs name the subnet `primary-<cluster>` |
| 10-26 | Read the NKP release from the `nkp:` line of `nkp version` | The first line is the catalog version (for example `v0.11.1`) |
| 10-26 | Pro sizing by default for the management cluster (3 × 4 vCPU / 16 GiB, 4 × 8 vCPU / 32 GiB); Starter refused for a management cluster unless confirmed, and failed by `--check` | Starter nodes made Kommander time out on a real lab; this is also the documented Pro/Ultimate sizing |
| 10-26 | Subnet updates retry a failed Prism Central task twice, 30 s apart, and show its error | Restoring the pool right after VM deletion failed with "Logical timestamp mismatch" |
| 10-26 | `--destroy` deletes a cluster that never left the bootstrap cluster through `~/.kube/config`; kubeconfigs are archived, and moved aside before a new create | A failed second run left a stale kubeconfig, which made the error messages wrong |
| 10-28 | Tests moved into the repo with one runner; fresh TLS certificate per run | They lived in `/tmp`, and the fixed test certificate had expired |
| 10-28 | No tmux relaunch without a terminal | Agent runs over SSH have no terminal, and the relaunch needs one |
| 10-30 | During management create, background-mirror `mesosphere/kommander-applications` → `kommander-applications-full` in the in-cluster registry | GitClaim's immutable OCI URL is `…/kommander-applications-full:v2.19.0`; some air-gap seeds only push the short name, so Kommander never past Creating GitClaim |
| 10-30 | `harbor_deploy` enables `rook-ceph` + `rook-ceph-cluster` (OSD overrides) and waits for `dkp-object-store` / ObjectBucketClaim CRD before claiming the Harbor bucket | Previously only warned when Rook was missing, then failed creating `ObjectBucketClaim` |
| 10-30 | `harbor_deploy` enables `kube-prometheus-stack` and waits for the `PrometheusRule` CRD before enabling Harbor | Harbor's CNPG chart installs PrometheusRules; without the CRD the `harbor-database` HelmRelease fails |
| 10-30 | Harbor readiness waits on `kommander` HelmReleases whose names start with `harbor`, plus `ncr-system/harbor-admin-password` | Flux creates those HelmReleases in `kommander` (release namespace `ncr-system`); waiting only in `ncr-system` never saw Ready |
| 10-30 | `post_workload` resolves the real CAPI/NKPCluster namespace via `kubectl get nkpclusters -A`, waits for `Available`/`Provisioned`, treats NKPCluster `Reconciled` as joined, and waits for HelmReleases in that workspace namespace | NKP 2.19 places the workload in `nkp-workload1-<suffix>`; CAPI Cluster v1 has no `Ready` condition; apps are not in `kommander` on the workload |

## 6. What the real-lab runs taught

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Unable to find a match: docker-ce-cli-3:27.4.0-1.el9` | Different RPM epochs for `docker-ce` and `docker-ce-cli` | Resolve each version separately |
| `--nutanix-registry-username and --nutanix-registry-password are required` | Self-managed clusters need registry credentials unless air-gapped | Ask for the portal token; later optional with the bundle |
| Preflight: `failed to list domain managers` (Prism Central v4.4 API) | Untrusted Prism Central certificate | `--insecure` by default when the certificate is not trusted |
| `12 out of 14 core applications have been deployed`, VMs left running, script suggested a rerun | Two Starter workers were too small; the cluster existed | At least 4 workers; `--status` instead of "rerun" |
| `--check`: `'Primary' not found`, real name `primary-<cluster>` | Template default too specific | Blank default with `primary(-...)` matching, and a suggestion |
| `--check`: `nkp CLI catalog: v0.11.1` | Read the first line of `nkp version` | Read the `nkp:` line |
| `Creating GitClaim for management GitRepository` then `timed out waiting for KommanderInitialized` | Starter sizing (2 vCPU / 8 GiB control plane, 4 vCPU / 8 GiB workers); probes timed out | Pro sizing default; honest status when no HelmReleases exist |
| GitClaim Ready=False / pre-receive declined; OCI `kommander-applications-full` missing | Air-gap seed had `mesosphere/kommander-applications` but GitClaim wants `-full` | Copy/retag applications → applications-full in the in-cluster registry, then delete/recreate GitClaim |
| Harbor deploy: `ObjectBucketClaim` / no Rook | `harbor_deploy` only warned when `rook-ceph-cluster` AppDeployment was absent | Enable `rook-ceph` + `rook-ceph-cluster` (with OSD overrides) and wait for `dkp-object-store` |
| Harbor database HelmRelease fails on `PrometheusRule` CRD | Harbor CNPG chart needs monitoring CRDs | Enable `kube-prometheus-stack` before Harbor |
| Harbor wait never finished though pods were Ready | Wait loop looked for HelmReleases in `ncr-system`; they live in `kommander` | Wait on kommander `harbor*` HelmReleases + `ncr-system/harbor-admin-password` |
| Workload “not Ready after 60m” / kubeconfig missing though VMs Ready | CAPI/NKPCluster lived in `nkp-workload1-<suffix>`, not `kommander-default-workspace` | Resolve namespace via `kubectl get nkpclusters -A` and wait/fetch there |
| Script hung on `kubectl wait --for=condition=Ready` for Cluster though VMs/NKPCluster were fine | CAPI Cluster v1 uses `Available` (and `phase=Provisioned`); there is no `Ready` condition | Wait for `condition=Available` or `phase=Provisioned`; treat NKPCluster `Reconciled` as success |
| `--destroy`: `Logical timestamp mismatch: request=23 current=24` | Prism Central was still updating the subnet as the deleted VMs released their addresses | Re-read the subnet and retry |
| `Waiting for cluster control-planes to be ready` timed out after 60 min; kubeconfig fails with `x509: certificate signed by unknown authority` | Not yet known (section 8). The x509 error came from the previous cluster's kubeconfig | Stale kubeconfig handling; diagnostics printed; root cause open |

## 7. Testing

`tests/run-all.sh` runs everything offline in about three minutes and exits 1 on any failure. It needs bash 4+ (it re-executes itself with Homebrew's bash on macOS), python3 3.9+ and openssl; ShellCheck runs when installed.

| Layer | What it proves |
| --- | --- |
| `bash -n`, ShellCheck, Python syntax | The files parse; shell lint is clean |
| `test_nkp_lab.py` (26 tests) | Every `nkp_lab.py` command against a fake Prism Central and Harbor: inventory, IP plan, subnet updates and retries, capacity, Harbor project, robot and login, `kubectl`-based queries |
| `tests/mock.sh` (75 checks) | Shell logic with everything external mocked: prompts under `--unattended`, answers files, remediation, destroy order, the bootstrap-held destroy, summaries, tmux behaviour |
| `tests/integration.sh` (110 checks) | The shell calling the real `nkp_lab.py` over TLS: inventory, IP plan, Harbor deploy and push decisions, workload registry flags, and `--check` scenarios (ready lab, wrong password, subnet spelling, unextracted package, Starter sizing, existing cluster with an external registry) |
| `tests/lab-e2e.sh` | A complete `--lab` and the workload child run, checking that both finish, nothing errors, and no secret lands in a file |

What the tests cannot prove: anything about real NKP, Harbor, Rook Ceph or Prism Central behaviour beyond what the fakes encode. The fake server's responses were written from the API documentation and the real-lab output above.

`--check` is the bridge: it runs the read-only parts against the real lab.

GitHub Actions runs only the `nkp_lab.py` unit tests; run `tests/run-all.sh` yourself before committing shell changes.

## 8. Open issues and unverified assumptions

1. **Earlier “control plane never Ready on bootstrap” (pre–10-30).** Still useful if a create stalls before the management kubeconfig exists: inspect with `nkp describe cluster` / machines on the bootstrap kubeconfig, `capx-system` logs, and control-plane `cloud-init` / kubelet. Candidates remain slow DHCP (NCN-115035), endpoint IP conflict, or bootstrap registry reachability. Two Pro-sizing end-to-end runs on 10-30 completed past this stage.
2. **Harbor S3 settings are still a best guess.** Real 2.19 labs accepted `harbor_s3_values` + Rook `dkp-object-store`, but compare against a UI-deployed Harbor ConfigMap when upgrading NKP; `HARBOR_OVERRIDES_FILE` replaces the built-in values.
3. **`kommander-applications-full` may be missing from some air-gap seeds.** The script mirrors `kommander-applications` → `kommander-applications-full` in the in-cluster registry during create. If a future bundle ships a *different* digest under `-full`, prefer the real artifact over the copy.
4. **Workload sizing default is still `WL_SIZING=starter`.** Management uses Pro; workload Pro is recommended when capacity allows but is not the default yet.
5. **Every run without `--skip-prereqs` unpacks the package again** (tens of GiB). Skip when an unpacked copy of the same package exists.
6. **`nkp get kubeconfig -c … -n …` is required** for workload clusters in a dedicated namespace (`nkp-workload1-<suffix>`). Omitting `-n` or using only `kommander-default-workspace` fails even when the cluster is healthy.
7. `cluster-dryrun.yaml` contains credentials because nkp renders them into secrets; it is mode 600, but still on disk.
8. **Windows agents / PowerShell:** piping a password into `ssh` with PowerShell's default encoding can send UTF-16 and cause Prism Central `401`. Write the password as UTF-8 bytes to the SSH process stdin (or run the remote `IFS= read -r NUTANIX_PASSWORD` pattern from a UTF-8-aware host).

## 9. Working on the script

- **Source of NKP truth:** the owner's NotebookLM notebook named "NKP", which holds the 2.19 documentation. Query it, not the web, when a question is about NKP behaviour, flags or sizing.
- **Before every commit:** `tests/run-all.sh` must pass. Add a test for every behaviour change: unit tests for `nkp_lab.py`, mocks or integration scenarios for the shell, and a `--check` scenario when the check changes.
- **Style:** match the surrounding code. Short comments only for constraints the code cannot show. Python stays standard library and 3.9 compatible. Shell output uses `step`, `ok`, `info`, `warn`, `err`, `die`, `row`.
- **Secrets:** never on a command line, never in an answers file or the repo. New secret-bearing files are mode 600.
- **The repo is public:** keep lab-specific details (addresses, cluster names, hostnames, tokens, download links) out of code, tests and docs.
- **Publishing:** this is GitHub, not Gerrit; changes go to `main` after the owner approves the push. Only the files in this repo are published, never the rest of the owner's workspace.
- **Real-lab validation:** run `--check` first, then the deployment; collect the failure output and `--status` before changing code, and turn each real failure into a test (section 6 is the history of that).
