# gpuctl

GPU resource dashboard for NVIDIA DGX clusters. Shows whole-GPU and MIG-slice availability across Kubernetes worker nodes.

Runs from the BCM head/login node. Reads Kubernetes data only -- never modifies cluster state.

## Requirements

- Bash 4.4+
- `kubectl` (configured with cluster access)
- `jq`
- `whiptail` (optional -- enables richer TUI dialogs)

## Install

```bash
sudo bash install.sh
```

This copies the script to `/usr/local/bin/gpuctl` and libraries to `/usr/local/lib/gpuctl/`. A default config is placed at `/etc/gpuctl/gpuctl.conf` if one doesn't already exist.

After installing, create a sudoers entry so all users can run it:

```bash
sudo visudo -f /etc/sudoers.d/gpuctl
```

Add:

```
ALL ALL=(root) NOPASSWD: /usr/local/bin/gpuctl
```

## Uninstall

```bash
sudo bash uninstall.sh
```

Then remove the sudoers entry manually:

```bash
sudo rm /etc/sudoers.d/gpuctl
```

## Usage

```
gpuctl [OPTIONS]

Options:
  --cli, --text       Plain-text output (no TUI)
  --node <name>       Show a specific node only
  --refresh <secs>    Override TUI refresh interval
  --help, -h          Show help
  --version, -v       Show version
```

**Examples:**

```bash
sudo gpuctl                         # Interactive TUI dashboard
sudo gpuctl --cli                   # One-shot plain text report
sudo gpuctl --cli --node dgx-03    # Single node report
sudo gpuctl --refresh 60           # TUI with 60s refresh
```

## TUI Keys

| Key | Action |
|-----|--------|
| R | Refresh now |
| N | Node detail view |
| H / ? | Help |
| Q / Esc | Quit |

## Configuration

Edit `/etc/gpuctl/gpuctl.conf` to customize settings. See `gpuctl.conf.example` for all available options with descriptions.

Key settings: `REFRESH_INTERVAL`, `DEFAULT_MODE`, `NODE_SELECTOR`, `MIG_PROFILES`.
