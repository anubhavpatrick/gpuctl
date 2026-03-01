# ============================================================================
# gpuctl/config - Constants, Defaults, and Configuration Loading
# ============================================================================
# Defines version constants, configurable default values for GPU resource
# discovery, node labeling, and refresh behavior.  Provides load_config()
# to parse the on-disk configuration file safely (without sourcing it),
# and build_resource_arrays() to derive the MIG profile arrays.
#
# Sourced by the main gpuctl script.  Do not execute directly.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# ============================================================================
# CONSTANTS
# ============================================================================

readonly GPUCTL_VERSION="1.0.0"
readonly GPUCTL_CONFIG_PATH="/etc/gpuctl/gpuctl.conf"
readonly GPUCTL_INSTALL_PATH="/usr/local/bin/gpuctl"

# ============================================================================
# CONFIGURABLE DEFAULTS
# ============================================================================
# Every value below can be overridden in the configuration file.
# Defaults are chosen for a standard NVIDIA DGX cluster running the
# NVIDIA GPU Operator with GPU Feature Discovery.

# --- General ---
readonly DEFAULT_REFRESH_INTERVAL=5
readonly DEFAULT_OUTPUT_MODE="tui"

# --- Node Discovery ---
# Label used as a kubectl selector to find GPU-enabled worker nodes.
# Format: "key=value" -- passed directly to `kubectl get nodes -l`.
readonly DEFAULT_NODE_SELECTOR="nvidia.com/gpu.present=true"

# --- GPU Resource Names ---
# Prefix that the NVIDIA device plugin uses for all GPU extended resources.
# Used to match resource requests in pod specs (e.g., "nvidia.com/gpu",
# "nvidia.com/mig-2g.35gb").
readonly DEFAULT_GPU_RESOURCE_PREFIX="nvidia.com/"

# Extended resource name for whole (non-MIG) GPUs.
readonly DEFAULT_WHOLE_GPU_RESOURCE="nvidia.com/gpu"

# Known MIG profiles -- comma-separated SHORT names (without the
# "nvidia.com/mig-" prefix).  The script prepends the prefix automatically.
# Order determines display order in tables (smallest to largest slice).
# Profiles with zero allocatable instances still appear in per-node tables
# (shown as 0 / - / -) but are hidden from the cluster summary.
readonly DEFAULT_MIG_PROFILES="1g.10gb,1g.18gb,1g.20gb,1g.35gb,2g.20gb,2g.35gb,3g.40gb,3g.71gb,4g.71gb,7g.141gb"

# --- Node Label Keys ---
# Labels applied by NVIDIA GPU Feature Discovery.  Each key maps to a piece
# of metadata displayed in node detail views and the TUI dashboard.
readonly DEFAULT_LABEL_GPU_PRODUCT="nvidia.com/gpu.product"
readonly DEFAULT_LABEL_GPU_MACHINE="nvidia.com/gpu.machine"
readonly DEFAULT_LABEL_GPU_COUNT="nvidia.com/gpu.count"
readonly DEFAULT_LABEL_GPU_MEMORY="nvidia.com/gpu.memory"
readonly DEFAULT_LABEL_MIG_CAPABLE="nvidia.com/mig.capable"
readonly DEFAULT_LABEL_MIG_CONFIG="nvidia.com/mig.config"
readonly DEFAULT_LABEL_MIG_STRATEGY="nvidia.com/mig.strategy"
readonly DEFAULT_LABEL_CUDA_DRIVER="nvidia.com/cuda.driver-version.full"

# ============================================================================
# CONFIGURATION
# ============================================================================

# Runtime configuration -- populated from defaults, then overridden by config
# file, then by CLI args (highest priority, per FR-21).
REFRESH_INTERVAL="$DEFAULT_REFRESH_INTERVAL"
OUTPUT_MODE="$DEFAULT_OUTPUT_MODE"
FILTER_NODE=""          # empty = show all nodes
TUI_BACKEND=""          # "whiptail" or "ansi", detected at runtime

# Configurable discovery / label settings (populated from defaults, then config)
NODE_SELECTOR="$DEFAULT_NODE_SELECTOR"
GPU_RESOURCE_PREFIX="$DEFAULT_GPU_RESOURCE_PREFIX"
WHOLE_GPU_RESOURCE="$DEFAULT_WHOLE_GPU_RESOURCE"
MIG_PROFILES_CSV="$DEFAULT_MIG_PROFILES"

LABEL_GPU_PRODUCT="$DEFAULT_LABEL_GPU_PRODUCT"
LABEL_GPU_MACHINE="$DEFAULT_LABEL_GPU_MACHINE"
LABEL_GPU_COUNT="$DEFAULT_LABEL_GPU_COUNT"
LABEL_GPU_MEMORY="$DEFAULT_LABEL_GPU_MEMORY"
LABEL_MIG_CAPABLE="$DEFAULT_LABEL_MIG_CAPABLE"
LABEL_MIG_CONFIG="$DEFAULT_LABEL_MIG_CONFIG"
LABEL_MIG_STRATEGY="$DEFAULT_LABEL_MIG_STRATEGY"
LABEL_CUDA_DRIVER="$DEFAULT_LABEL_CUDA_DRIVER"

# Derived arrays -- built by build_resource_arrays() after config is loaded.
# Declared here so they exist at global scope.
declare -a KNOWN_MIG_PROFILES=()    # fully-qualified: "nvidia.com/mig-1g.35gb" ...
declare -a ALL_RESOURCE_TYPES=()    # whole GPU + all MIG profiles

# Build the MIG profile and resource type arrays from the (possibly
# user-overridden) configuration values.  Must be called after load_config().
#
# Side effects:
#   - Populates KNOWN_MIG_PROFILES and ALL_RESOURCE_TYPES arrays
build_resource_arrays() {
    KNOWN_MIG_PROFILES=()
    ALL_RESOURCE_TYPES=()

    # Split the comma-separated MIG profile list into an array.
    # IFS=',' causes read to split on commas; -ra reads into an indexed array.
    local -a profiles=()
    IFS=',' read -ra profiles <<< "$MIG_PROFILES_CSV"

    local profile trimmed
    for profile in "${profiles[@]}"; do
        # Trim whitespace from each entry (allows "1g.35gb, 2g.35gb" spacing)
        trimmed="$(echo "$profile" | tr -d '[:space:]')"
        [[ -z "$trimmed" ]] && continue
        # Prepend the resource prefix + "mig-" to form the full K8s resource name
        KNOWN_MIG_PROFILES+=( "${GPU_RESOURCE_PREFIX}mig-${trimmed}" )
    done

    ALL_RESOURCE_TYPES=( "$WHOLE_GPU_RESOURCE" "${KNOWN_MIG_PROFILES[@]}" )
}

# Parse the configuration file safely without sourcing it.
# Manual key=value parsing prevents code injection via a malicious config.
#
# Side effects:
#   - Sets all configurable globals (REFRESH_INTERVAL, OUTPUT_MODE,
#     NODE_SELECTOR, GPU_RESOURCE_PREFIX, WHOLE_GPU_RESOURCE, MIG_PROFILES_CSV,
#     LABEL_GPU_PRODUCT, LABEL_GPU_MACHINE, LABEL_GPU_COUNT, LABEL_GPU_MEMORY,
#     LABEL_MIG_CAPABLE, LABEL_MIG_CONFIG, LABEL_MIG_STRATEGY, LABEL_CUDA_DRIVER)
#   - Calls build_resource_arrays() to rebuild derived arrays
load_config() {
    [[ -f "$GPUCTL_CONFIG_PATH" ]] || { build_resource_arrays; return 0; }

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Split on first '=' only; trim surrounding whitespace
        key="${line%%=*}"
        value="${line#*=}"
        # ${var%%pattern} removes longest suffix match; ${var#pattern} removes
        # shortest prefix match -- together they isolate key and value.

        # Strip leading/trailing whitespace from key and value
        key="$(echo "$key" | tr -d '[:space:]')"
        value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        case "$key" in
            # --- General ---
            REFRESH_INTERVAL)
                # Validate: must be a positive integer
                if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )); then
                    REFRESH_INTERVAL="$value"
                else
                    echo "Warning: Invalid REFRESH_INTERVAL='$value' in config, using default ($DEFAULT_REFRESH_INTERVAL)." >&2
                fi
                ;;
            DEFAULT_MODE)
                # ${value,,} converts to lowercase for case-insensitive comparison
                case "${value,,}" in
                    tui|cli) OUTPUT_MODE="${value,,}" ;;
                    *)
                        echo "Warning: Invalid DEFAULT_MODE='$value' in config, using default ($DEFAULT_OUTPUT_MODE)." >&2
                        ;;
                esac
                ;;

            # --- Node Discovery ---
            NODE_SELECTOR)
                # Validate: must contain '=' (key=value format for kubectl -l)
                if [[ "$value" == *"="* ]]; then
                    NODE_SELECTOR="$value"
                else
                    echo "Warning: Invalid NODE_SELECTOR='$value' (must be key=value), using default." >&2
                fi
                ;;

            # --- GPU Resource Names ---
            GPU_RESOURCE_PREFIX)
                # Accept any non-empty string; prefix is used in jq startswith()
                if [[ -n "$value" ]]; then
                    GPU_RESOURCE_PREFIX="$value"
                else
                    echo "Warning: Empty GPU_RESOURCE_PREFIX in config, using default." >&2
                fi
                ;;
            WHOLE_GPU_RESOURCE)
                if [[ -n "$value" ]]; then
                    WHOLE_GPU_RESOURCE="$value"
                else
                    echo "Warning: Empty WHOLE_GPU_RESOURCE in config, using default." >&2
                fi
                ;;
            MIG_PROFILES)
                # Accept any non-empty comma-separated list
                if [[ -n "$value" ]]; then
                    MIG_PROFILES_CSV="$value"
                else
                    echo "Warning: Empty MIG_PROFILES in config, using default." >&2
                fi
                ;;

            # --- Node Label Keys ---
            LABEL_GPU_PRODUCT)   [[ -n "$value" ]] && LABEL_GPU_PRODUCT="$value"  ;;
            LABEL_GPU_MACHINE)   [[ -n "$value" ]] && LABEL_GPU_MACHINE="$value"  ;;
            LABEL_GPU_COUNT)     [[ -n "$value" ]] && LABEL_GPU_COUNT="$value"    ;;
            LABEL_GPU_MEMORY)    [[ -n "$value" ]] && LABEL_GPU_MEMORY="$value"   ;;
            LABEL_MIG_CAPABLE)   [[ -n "$value" ]] && LABEL_MIG_CAPABLE="$value"  ;;
            LABEL_MIG_CONFIG)    [[ -n "$value" ]] && LABEL_MIG_CONFIG="$value"   ;;
            LABEL_MIG_STRATEGY)  [[ -n "$value" ]] && LABEL_MIG_STRATEGY="$value" ;;
            LABEL_CUDA_DRIVER)   [[ -n "$value" ]] && LABEL_CUDA_DRIVER="$value"  ;;

            *)
                # Silently ignore unknown keys for forward compatibility
                ;;
        esac
    done < "$GPUCTL_CONFIG_PATH"

    # Rebuild derived arrays with (possibly overridden) values
    build_resource_arrays
}
