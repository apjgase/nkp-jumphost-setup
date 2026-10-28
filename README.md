# nkp-jumphost-setup

Builds an NKP 2.19 lab on Nutanix AHV from a Linux jump host. It creates a self-managed management cluster from the dark site (air-gapped) bundle, deploys Harbor on that cluster and pushes the bundle images into it, and then creates workload clusters that pull from that Harbor. It also works from the internet without a bundle.

## Quickstart

On the jump host, as root or a user with sudo:

```bash
curl -fsSL https://github.com/apjgase/nkp-jumphost-setup/archive/refs/heads/main.tar.gz | tar -xzf - && cd nkp-jumphost-setup-main
```

Put the NKP 2.19 package from the Nutanix Portal (`nkp-air-gapped-bundle_v2.19.x_linux_amd64.tar.gz`, about 37 GB) in your home directory or `~/Downloads`, then:

```bash
./nkp-jumphost-setup.sh --prereqs-only          # Docker, kubectl, nkp CLI, tmux; unpacks the bundle into ~/nkp-dist
./nkp-jumphost-setup.sh --init-config           # writes ./nkp-lab.env; set NUTANIX_ENDPOINT and anything not discovered
export NUTANIX_PASSWORD                         # read -rs NUTANIX_PASSWORD first, so it stays out of your shell history
./nkp-jumphost-setup.sh --check --config nkp-lab.env                   # read-only readiness test, changes nothing
./nkp-jumphost-setup.sh --lab --skip-prereqs --config nkp-lab.env      # management cluster, Harbor, first workload cluster
```

`--lab` takes 2 to 3 hours. It reruns itself inside a tmux session named `nkp`, so you can disconnect and later reattach with `tmux attach -t nkp`. When it finishes, `~/nkp/lab-summary.txt` lists the dashboard URL and login, the Harbor URL, and the kubeconfig paths.

## Modes

| Option | What it does |
| --- | --- |
| `--check` | Read-only test of the jump host and the lab: tools, bundle, Prism Central login and inventory, IP plan dry run, lab DNS, capacity and sizing. Exits 1 if anything fails. Report in `~/nkp/lab-check.txt` |
| *(none)* | Prerequisites, the management cluster and, with the bundle, Harbor; then offers to create a workload cluster |
| `--lab` | Prerequisites, management cluster, Harbor and the bundle push, then the first workload cluster |
| `--harbor` | Deploys Harbor on the management cluster (if it is missing) and pushes the bundle into it |
| `--workload` | Creates another workload cluster, attached to a workspace, pulling from Harbor |
| `--status` | Shows what is not ready yet on clusters this script created |
| `--destroy` | Deletes the workload clusters and the management cluster, then restores the subnet's IP pool and DHCP settings |
| `--prereqs-only`, `--skip-prereqs` | Runs only the prerequisites, or everything except them |
| `--config FILE`, `--init-config` | Uses an answers file, or writes a commented template to `./nkp-lab.env` |
| `--unattended` | Never prompts: takes the answers file and defaults, stops on anything missing |
| `--print-only`, `--no-ip-plan` | Prints the `nkp create cluster` command instead of running it, or leaves the subnet untouched |

`./nkp-jumphost-setup.sh --help` lists every option. `nkp_lab.py` must stay next to the script.

## Secrets

Passwords are never read from or written to the answers file. The script prompts for them, or takes them from the environment:

| Variable | Needed for |
| --- | --- |
| `NUTANIX_PASSWORD` | Prism Central, always. Required with `--unattended` |
| `NUTANIX_REGISTRY_PASSWORD` | The Nutanix registry token. Optional when the bundle is used |
| `DOCKERHUB_PASSWORD` | Only with `USE_DOCKERHUB=Y` |
| `REGISTRY_MIRROR_PASSWORD` | Only with `REGISTRY_MIRROR_URL` (an existing registry instead of Harbor) |
| `NKP_DESTROY_CONFIRM` | Not a secret: the management cluster name, to confirm `--destroy --unattended` |

The script passes secrets to its Python helper through the environment, never on command lines. Files that hold credentials, such as kubeconfigs, `lab-summary.txt` and the preflight `cluster-dryrun.yaml`, are mode 600 under `~/nkp`.

## Lab assumptions

- **Jump host**: Linux with cgroups v2. Rocky Linux and RHEL 9 are tested, with Python 3.9 or later. It needs at least 4 CPUs and 4 GiB of free memory for the bootstrap cluster, and disk for about twice the bundle size in the home directory and 30 GiB more than the bundle in `/var/lib`. It must reach Prism Central on port 9440 and the node subnet. The internet is needed only without the bundle.
- **Prism Central** with the v3 API. It manages the target Prism Element cluster and has an NKP Rocky node image for Kubernetes 1.36 (blank `VM_IMAGE` picks the only image whose name contains `1.36`).
- **One VLAN subnet with IPAM.** The default name is `primary` or `primary-<cluster>`. The script reserves a block of 12 to 30 addresses at the end of its IP pool, used for the API addresses and load balancer ranges, and shrinks the pool accordingly. `--destroy` puts it back.
- **Lab DNS**: a VM named `autoad` serving the `ntnxlab.local` domain, as in Nutanix hosted POC labs. When it is present, the subnet's DHCP hands it out as DNS server. Otherwise the DNS settings are left alone. Override with `LAB_DNS_VM` and `LAB_DOMAIN`.
- **Sizing**: `SIZING=pro` (3 control-plane nodes with 4 vCPU and 16 GiB, 4 workers with 8 vCPU and 32 GiB, 80 GB disks) for the management cluster. Starter is too small for it, because the platform apps and Harbor's Rook Ceph storage do not fit. `--check` compares the plan with the free cluster capacity.
- **Nodes** get the SSH user `nkpadmin` with `~/.ssh/id_ed25519.pub`, which is generated if it is missing.

## More

- [docs/PROJECT-REVIEW.md](docs/PROJECT-REVIEW.md): architecture, decisions, real-lab lessons, open issues.
- [docs/AGENT-DEPLOY.md](docs/AGENT-DEPLOY.md): how an AI agent runs a deployment over SSH.
- Tests: `tests/run-all.sh` runs everything offline. CI runs `python3 -m unittest test_nkp_lab`.

## License

[MIT](LICENSE)
