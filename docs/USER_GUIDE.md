# gpuctl - User Guide

**Version**: 1.0 | **Date**: 2026-03-01

This guide introduces `gpuctl`, a command-line tool that reports GPU availability on a shared NVIDIA DGX cluster. It is written for users who may not have prior experience with GPU partitioning or Kubernetes resource management.

---

## 1. Why This Tool Exists

In a shared GPU cluster, multiple users submit computational workloads (such as AI model training) that require GPU resources. Before submitting a job, you need to know **which GPU resources are currently available** across the cluster's servers.

Without `gpuctl`, there is no straightforward way to answer this question from the login node. Users would have to guess resource availability and face scheduling failures when requesting resources that are already occupied.

`gpuctl` queries the cluster and presents a clear summary of what is free, what is in use, and what each server offers.

---

## 2. Key Concepts

### 2.1 GPUs in High-Performance Computing

GPUs (Graphics Processing Units) excel at parallel computation, making them essential hardware for training and running AI/ML models. A single DGX server in this cluster contains **8 high-end GPUs** (e.g., NVIDIA H200), each with substantial memory (140+ GB).

### 2.2 MIG: Multi-Instance GPU

NVIDIA's **MIG** (Multi-Instance GPU) technology allows a single physical GPU to be **partitioned into smaller, isolated slices**. Each slice has its own dedicated compute cores and memory, and operates independently of other slices on the same GPU.

This is useful because not every workload requires an entire GPU. A large training run may need a full GPU (or several), while a smaller experiment may only need a fraction. MIG allows efficient sharing of expensive hardware.

MIG slices are identified by a **profile name** such as `1g.35gb` or `2g.35gb`:
- The first part (`1g`, `2g`, `3g`...) indicates the **compute partition size** (number of GPU engine slices).
- The second part (`35gb`, `71gb`...) indicates the **memory allocation**.

The cluster administrator decides how GPUs are partitioned. A given server may have some GPUs left whole and others split into MIG slices.

### 2.3 Kubernetes and Resource Scheduling

The cluster uses **Kubernetes** (K8s) to manage workloads. When you submit a job, you specify what GPU resources it needs in a configuration file. Kubernetes then finds a server with matching available resources and runs your job there.

GPU resources appear in Kubernetes as **extended resource names**:

| Resource Name | Meaning |
|---------------|---------|
| `nvidia.com/gpu` | One whole (unpartitioned) GPU |
| `nvidia.com/mig-1g.35gb` | A 1g.35gb MIG slice |
| `nvidia.com/mig-2g.35gb` | A 2g.35gb MIG slice |
| `nvidia.com/mig-3g.71gb` | A 3g.71gb MIG slice |

These are the exact names you use when requesting resources in your Kubernetes job manifest.

---

## 3. Using gpuctl

### 3.1 Launching

From the login node terminal:

```bash
gpuctl
```

This opens an **interactive dashboard** that refreshes automatically. No additional privileges or flags are needed -- the tool handles access internally.

### 3.2 Understanding the Output

The dashboard displays two sections:

**Cluster Summary** -- aggregated across all servers:

```
Resource                   Total     In-Use    Available
nvidia.com/gpu                14          5            9
nvidia.com/mig-2g.35gb        6          3            3
```

**Per-Node Breakdown** -- for each server individually:

```
NODE: gu-k8s-worker-01           GPU: NVIDIA-H200
Resource                   Total     In-Use    Available
nvidia.com/gpu                 7          2            5
nvidia.com/mig-2g.35gb        3          1            2
```

The three columns mean:

| Column | Definition |
|--------|------------|
| **Total** | Number of this resource the server makes available for scheduling |
| **In-Use** | Number currently consumed by running workloads |
| **Available** | Number free for new workloads (`Total - In-Use`) |

If **Available > 0** for a resource, you can request it in your job configuration.

### 3.3 Dashboard Controls

| Key | Action |
|-----|--------|
| **R** | Refresh immediately |
| **N** | View a specific node in detail |
| **H** / **?** | Help |
| **Q** / **Esc** | Quit |

### 3.4 Plain-Text Mode (CLI-Only Usage)

If you prefer not to use the interactive dashboard, you can run `gpuctl` in CLI-only mode using the `--cli` or `--text` flag:

```bash
gpuctl --cli
```

This prints the GPU summary once to standard output and exits immediately. It is the recommended approach if you only need a quick status check, want to copy the output, or are working in an environment where the interactive dashboard is not practical.

To view a specific server only:

```bash
gpuctl --cli --node gu-k8s-worker-01
```

---

## 4. Command Reference

```
gpuctl [OPTIONS]

Options:
  --cli, --text       Plain-text output (no interactive dashboard)
  --node <name>       Show only the specified server
  --refresh <secs>    Set dashboard refresh interval (default: 5 seconds)
  --help, -h          Show usage information
  --version, -v       Show version
```

---

## 5. Connecting gpuctl Output to Your Workload

When you see available resources in `gpuctl`, use the **exact resource name** in the `resources.limits` section of your Kubernetes pod or job manifest.

For a whole GPU:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

For a MIG slice:

```yaml
resources:
  limits:
    nvidia.com/mig-2g.35gb: 1
```

Kubernetes will schedule your workload on a node that has the requested resource available.

---

## 6. Frequently Asked Questions

**Does this tool modify anything on the cluster?**
No. `gpuctl` only reads data. It cannot start, stop, or alter any workload or cluster configuration.

**A resource shows 0 in the Total column. Is something wrong?**
No. It means that MIG profile is not configured on that particular server. The administrator provisions different MIG profiles on different nodes based on demand.

**What if the dashboard shows no data or all zeros?**
The cluster may be undergoing maintenance or reconfiguration. Contact your system administrator.
