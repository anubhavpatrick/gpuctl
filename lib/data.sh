# ============================================================================
# gpuctl/data - Kubernetes Data Collection and Aggregation
# ============================================================================
# Handles all interaction with the Kubernetes API via kubectl.  Fetches
# GPU-enabled node metadata and per-node pod resource usage, then computes
# cluster-wide aggregates.  Exposes accessor functions for allocatable,
# in-use, and label data used by the CLI and TUI renderers.
#
# Sourced by the main gpuctl script.  Do not execute directly.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# ============================================================================
# DATA COLLECTION
# ============================================================================

# Associative arrays for per-node data storage.
# Keys are node names; values are JSON strings or delimited data.
# -gA = global associative array.  The -g flag is required because this file
# is sourced from within the safe_source() function.  Without -g, `declare`
# creates function-local variables that are destroyed when safe_source returns,
# causing later associative subscripts (e.g., arr["node-name"]) to undergo
# arithmetic evaluation instead of string-key lookup.
declare -gA NODE_LABELS_JSON=()      # node -> full labels JSON object
declare -gA NODE_ALLOC_JSON=()       # node -> allocatable resources JSON object
declare -gA NODE_INUSE=()            # node -> "res1:count1,res2:count2,..." usage string

# Ordered list of node names (bash arrays preserve insertion order)
# -ga = global indexed array (see above for why -g is needed)
declare -ga NODE_LIST=()

# Cluster-level aggregation
declare -gA CLUSTER_ALLOC=()         # resource -> total allocatable across cluster
declare -gA CLUSTER_INUSE=()         # resource -> total in-use across cluster

# Fetch all GPU-enabled worker nodes in a single kubectl call.
# Populates NODE_LIST, NODE_LABELS_JSON, and NODE_ALLOC_JSON.
#
# Uses a single `kubectl get nodes` with label selector to minimize API calls
# (NFR-08: target under 5 seconds for up to 16 nodes).
#
# Returns:
#   0 on success
#   1 if no GPU nodes are found
fetch_gpu_nodes() {
    local nodes_json
    # -l = label selector; uses the configurable NODE_SELECTOR (default:
    # "nvidia.com/gpu.present=true") to find GPU-equipped worker nodes.
    nodes_json="$(kubectl get nodes \
        -l "${NODE_SELECTOR}" \
        -o json 2>/dev/null)" || die "Failed to query Kubernetes nodes."

    local node_count
    # jq '.items | length' counts the number of node objects returned
    node_count="$(echo "$nodes_json" | jq '.items | length')"

    if (( node_count == 0 )); then
        return 1
    fi

    # Reset arrays before populating
    NODE_LIST=()
    NODE_LABELS_JSON=()
    NODE_ALLOC_JSON=()

    local i name labels_json alloc_json
    for (( i = 0; i < node_count; i++ )); do
        # jq -r outputs raw strings (no quotes); .items[$i] indexes into the array
        name="$(echo "$nodes_json" | jq -r ".items[$i].metadata.name")"
        labels_json="$(echo "$nodes_json" | jq -c ".items[$i].metadata.labels")"
        alloc_json="$(echo "$nodes_json" | jq -c ".items[$i].status.allocatable")"

        NODE_LIST+=( "$name" )
        NODE_LABELS_JSON["$name"]="$labels_json"
        NODE_ALLOC_JSON["$name"]="$alloc_json"
    done

    return 0
}

# Fetch pod GPU usage for a single node by aggregating nvidia.com/* resource
# requests from all pods scheduled on that node.
#
# Arguments:
#   $1 - node_name: Target Kubernetes worker node
#
# Side effects:
#   - Populates NODE_INUSE[$node_name] with "res:count,..." string
#
# Security: Only aggregated counts are stored; pod names and namespaces
# are never captured or stored (NFR-04).
fetch_node_pod_usage() {
    local node_name="$1"

    # Query all pods on this node across all namespaces.
    # --field-selector filters server-side for efficiency.
    local pods_json
    pods_json="$(kubectl get pods \
        --all-namespaces \
        --field-selector "spec.nodeName=${node_name}" \
        -o json 2>/dev/null)" || {
        NODE_INUSE["$node_name"]=""
        return 0
    }

    # jq filter: compute per-node GPU usage following Kubernetes scheduling
    # semantics. Only Running/Pending pods consume resources; Completed, Failed,
    # and Evicted pods are excluded.
    #
    # Kubernetes effective resource request per pod per resource type:
    #   effective = max( max(initContainers[].requests), sum(containers[].requests) )
    # This accounts for init containers that may request GPUs for setup tasks.
    #
    # The filter uses a jq helper function `gpu_requests` to extract and sum/max
    # GPU resource requests from a container array, avoiding duplication.
    local usage_str
    # The prefix variable is interpolated into the jq filter via --arg, which
    # safely passes shell variables into jq without injection risk.
    usage_str="$(echo "$pods_json" | jq -r --arg prefix "$GPU_RESOURCE_PREFIX" '
        # Helper: extract GPU resource entries from a container array.
        # Returns array of {key, value} for resources matching the prefix.
        def gpu_requests:
            [.[]?.resources.requests // empty
             | to_entries[]
             | select(.key | startswith($prefix))
             | {key: .key, value: (.value | tonumber)}];

        # Filter to pods that actually hold resources (Running or Pending).
        # select() keeps only items where the condition is true.
        [.items[]
         | select(.status.phase == "Running" or .status.phase == "Pending")
         | {
             # Sum of regular container GPU requests per resource type
             cont: ([.spec.containers | gpu_requests
                     | group_by(.key)
                     | .[] | {key: .[0].key, value: (map(.value) | add)}]),
             # Max of init container GPU requests per resource type
             init: ([.spec.initContainers | gpu_requests
                     | group_by(.key)
                     | .[] | {key: .[0].key, value: (map(.value) | max)}])
           }
         | # Merge cont and init arrays, group by resource key, then take
           # max(container_sum, init_max) per resource type per pod
           (.cont + .init) | group_by(.key)
           | .[] | {key: .[0].key, value: (map(.value) | max)}
        ]
        # Aggregate across all pods: group by resource type, sum effective values
        | group_by(.key)
        | map({key: .[0].key, value: (map(.value) | add)})
        | map("\(.key):\(.value)")
        | join(",")
    ' 2>/dev/null)" || usage_str=""

    NODE_INUSE["$node_name"]="$usage_str"
}

# Orchestrate a full data refresh: fetch nodes, fetch per-node pod usage,
# compute cluster-wide aggregates.
#
# Returns:
#   0 on success
#   1 if no GPU nodes found
#
# Side effects:
#   - Populates all NODE_* and CLUSTER_* globals
refresh_data() {
    if ! fetch_gpu_nodes; then
        return 1
    fi

    # If filtering to a single node, verify it exists in the cluster
    if [[ -n "$FILTER_NODE" ]]; then
        local found=false
        local node
        for node in "${NODE_LIST[@]}"; do
            if [[ "$node" == "$FILTER_NODE" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            die "Node '$FILTER_NODE' not found among GPU-enabled worker nodes."
        fi
    fi

    # Fetch pod GPU usage for each node
    local node
    for node in "${NODE_LIST[@]}"; do
        fetch_node_pod_usage "$node"
    done

    # Compute cluster-wide aggregates
    compute_cluster_aggregates

    return 0
}

# Compute cluster-wide totals by summing per-node allocatable and in-use.
#
# Side effects:
#   - Populates CLUSTER_ALLOC and CLUSTER_INUSE associative arrays
compute_cluster_aggregates() {
    CLUSTER_ALLOC=()
    CLUSTER_INUSE=()

    local node res_type alloc inuse
    for node in "${NODE_LIST[@]}"; do
        for res_type in "${ALL_RESOURCE_TYPES[@]}"; do
            alloc="$(get_allocatable "$node" "$res_type")"
            inuse="$(get_inuse "$node" "$res_type")"

            # Use var=$(( )) form instead of standalone (( var = )) because
            # (( 0 )) returns exit code 1 which triggers set -e.
            CLUSTER_ALLOC["$res_type"]=$(( ${CLUSTER_ALLOC["$res_type"]:-0} + alloc ))
            CLUSTER_INUSE["$res_type"]=$(( ${CLUSTER_INUSE["$res_type"]:-0} + inuse ))
        done
    done
}

# Get a node label value.
#
# Arguments:
#   $1 - node_name
#   $2 - label_key (e.g., "nvidia.com/gpu.product")
#
# Returns (stdout):
#   The label value, or "-" if not present
get_node_label() {
    local node_name="$1" label_key="$2"
    local val
    # jq -r ".[key] // empty" returns the value or nothing if key is absent
    val="$(echo "${NODE_LABELS_JSON[$node_name]}" | jq -r ".[\"$label_key\"] // empty" 2>/dev/null)"
    echo "${val:-"-"}"
}

# Get the allocatable count for a resource type on a node.
#
# Arguments:
#   $1 - node_name
#   $2 - resource_type (e.g., "nvidia.com/gpu")
#
# Returns (stdout):
#   Integer count (0 if resource not present)
get_allocatable() {
    local node_name="$1" res_type="$2"
    local val
    val="$(echo "${NODE_ALLOC_JSON[$node_name]}" | jq -r ".[\"$res_type\"] // \"0\"" 2>/dev/null)"
    # Ensure output is always an integer
    echo "${val:-0}"
}

# Get the in-use count for a resource type on a node.
# Parses the "res:count,res:count,..." string stored in NODE_INUSE.
#
# Arguments:
#   $1 - node_name
#   $2 - resource_type (e.g., "nvidia.com/gpu")
#
# Returns (stdout):
#   Integer count (0 if resource not in use)
get_inuse() {
    local node_name="$1" res_type="$2"
    local usage_str="${NODE_INUSE[$node_name]:-}"

    [[ -z "$usage_str" ]] && { echo "0"; return; }

    local pair
    # IFS=',' splits the string on commas for iteration
    IFS=',' read -ra pairs <<< "$usage_str"
    for pair in "${pairs[@]}"; do
        # ${pair%%:*} extracts everything before the first colon (resource name)
        # ${pair##*:} extracts everything after the last colon (count)
        if [[ "${pair%%:*}" == "$res_type" ]]; then
            echo "${pair##*:}"
            return
        fi
    done

    echo "0"
}
