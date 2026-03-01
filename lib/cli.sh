# ============================================================================
# gpuctl/cli - CLI Mode Plain-Text Output
# ============================================================================
# Renders the cluster GPU report as plain text suitable for terminal output,
# piping, and scripting.  No ANSI escape sequences are used so that output
# remains parseable by downstream tools.
#
# Sourced by the main gpuctl script.  Do not execute directly.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# ============================================================================
# CLI MODE OUTPUT
# ============================================================================

# Print the full cluster GPU report in plain text (FR-16 to FR-18).
# No ANSI escape sequences -- output is parseable for piping/scripting.
#
# Side effects:
#   - Writes to stdout
print_cli_output() {
    local nodes_to_show=()

    if [[ -n "$FILTER_NODE" ]]; then
        nodes_to_show=( "$FILTER_NODE" )
    else
        nodes_to_show=( "${NODE_LIST[@]}" )
    fi

    # --- Cluster Summary (skip when filtering to a single node) ---
    if [[ -z "$FILTER_NODE" ]]; then
        # ${#nodes_to_show[@]} = array length
        echo "Cluster GPU Summary"
        echo "==================="
        printf "Worker Nodes with GPUs: %d\n" "${#nodes_to_show[@]}"
        echo ""

        # Table header
        printf "%-30s  %11s  %8s  %11s\n" "Resource Type" "Allocatable" "In-Use" "Available"
        printf "%-30s  %11s  %8s  %11s\n" "------------------------------" "-----------" "--------" "-----------"

        local res_type c_alloc c_inuse c_avail
        for res_type in "${ALL_RESOURCE_TYPES[@]}"; do
            c_alloc="${CLUSTER_ALLOC[$res_type]:-0}"
            c_inuse="${CLUSTER_INUSE[$res_type]:-0}"
            c_avail=$(( c_alloc - c_inuse ))

            # Cluster summary skips resource types with zero total (FR-10)
            (( c_alloc == 0 )) && continue

            printf "%-30s  %11d  %8d  %11d\n" "$res_type" "$c_alloc" "$c_inuse" "$c_avail"
        done

        echo ""
    fi

    # --- Per-Node Sections ---
    local node
    for node in "${nodes_to_show[@]}"; do
        local gpu_model machine_type gpu_count mig_capable mig_strategy mig_config

        gpu_model="$(get_node_label "$node" "$LABEL_GPU_PRODUCT")"
        machine_type="$(get_node_label "$node" "$LABEL_GPU_MACHINE")"
        gpu_count="$(get_node_label "$node" "$LABEL_GPU_COUNT")"
        mig_capable="$(get_node_label "$node" "$LABEL_MIG_CAPABLE")"
        mig_strategy="$(get_node_label "$node" "$LABEL_MIG_STRATEGY")"
        mig_config="$(get_node_label "$node" "$LABEL_MIG_CONFIG")"

        echo "---"
        printf "Node Name          : %s\n" "$node"
        printf "GPU Model          : %s\n" "$gpu_model"
        printf "Machine Type       : %s\n" "$machine_type"
        printf "Physical GPU Count : %s\n" "$gpu_count"
        printf "MIG Capable        : %s\n" "$mig_capable"
        printf "MIG Strategy       : %s\n" "$mig_strategy"
        printf "MIG Config         : %s\n" "$mig_config"
        echo ""

        printf "%-30s  %11s  %8s  %11s\n" "Resource Type" "Allocatable" "In-Use" "Available"
        printf "%-30s  %11s  %8s  %11s\n" "------------------------------" "-----------" "--------" "-----------"

        local res_type alloc inuse avail
        for res_type in "${ALL_RESOURCE_TYPES[@]}"; do
            alloc="$(get_allocatable "$node" "$res_type")"
            inuse="$(get_inuse "$node" "$res_type")"
            avail=$(( alloc - inuse ))

            # Resources with allocatable=0 show dashes for in-use/available
            if (( alloc == 0 )); then
                printf "%-30s  %11d  %8s  %11s\n" "$res_type" 0 "-" "-"
            else
                printf "%-30s  %11d  %8d  %11d\n" "$res_type" "$alloc" "$inuse" "$avail"
            fi
        done

        echo ""
    done
}
