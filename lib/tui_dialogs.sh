# ============================================================================
# gpuctl/tui_dialogs - Interactive Dialog Windows
# ============================================================================
# Provides modal dialog windows for the TUI: node selector (whiptail menu
# or numbered-prompt fallback), per-node detail view, and help overlay.
# Each dialog temporarily restores terminal state for user interaction,
# then re-enters raw mode for the dashboard.
#
# Sourced by the main gpuctl script.  Do not execute directly.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# ============================================================================
# INTERACTIVE DIALOGS (WHIPTAIL / ANSI FALLBACK)
# ============================================================================

# Show the node selector dialog and return the selected node name.
# Dispatches to whiptail or plain-text fallback based on TUI_BACKEND.
#
# Returns (stdout):
#   Selected node name, or empty string if cancelled
show_node_selector() {
    if [[ "$TUI_BACKEND" == "whiptail" ]]; then
        _node_selector_whiptail
    else
        _node_selector_ansi
    fi
}

# Node selector using whiptail --menu.
# Temporarily restores terminal state for the dialog, then re-hides cursor.
#
# Returns (stdout):
#   Selected node name, or empty string if cancelled
_node_selector_whiptail() {
    # Build menu items: "node_name" "description"
    local -a menu_items=()
    local node gpu_model gpu_count desc
    for node in "${NODE_LIST[@]}"; do
        gpu_model="$(get_node_label "$node" "$LABEL_GPU_PRODUCT")"
        gpu_count="$(get_node_label "$node" "$LABEL_GPU_COUNT")"
        desc="(${gpu_model}, ${gpu_count} GPUs)"
        menu_items+=( "$node" "$desc" )
    done

    local menu_height
    # ${#NODE_LIST[@]} = number of nodes; cap menu to 10 entries
    menu_height="${#NODE_LIST[@]}"
    (( menu_height > 10 )) && menu_height=10

    # Temporarily show cursor and enable echo for whiptail interaction.
    # Redirect tput output to /dev/tty so escape sequences don't leak into
    # stdout (this function runs inside $() capture in handle_keypress).
    tput cnorm >/dev/tty 2>/dev/null || true
    stty echo icanon 2>/dev/null || true

    local selected
    # whiptail --menu: title, height, width, list-height, then tag/item pairs.
    # --fb = full-size buttons (required so actbutton colors apply; compact
    # buttons use inverted compactbutton colors which can be hard to read).
    # Writes selection to stderr (3>&1 1>&2 2>&3 swaps stdout/stderr to capture).
    selected="$(whiptail --title "Select Worker Node" --fb \
        --menu "Choose a node to view details:" \
        $(( menu_height + 8 )) 50 "$menu_height" \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)" || selected=""

    # Re-hide cursor and disable echo for dashboard
    tput civis >/dev/tty 2>/dev/null || true
    stty -echo -icanon 2>/dev/null || true

    echo "$selected"
}

# Node selector using plain-text numbered prompts (ANSI fallback).
# Used when whiptail is not available.
#
# Returns (stdout):
#   Selected node name, or empty string if cancelled
_node_selector_ansi() {
    # All display output (tput, echo, printf prompts) is redirected to /dev/tty
    # so it doesn't leak into stdout when this function runs inside $() capture.
    # Only the final echo of the selected node goes to stdout (for capture).

    # Temporarily restore terminal for interactive input
    tput cnorm >/dev/tty 2>/dev/null || true
    stty echo icanon 2>/dev/null || true
    tput clear >/dev/tty 2>/dev/null || true

    echo "Select Worker Node" >/dev/tty
    echo "==================" >/dev/tty
    echo "" >/dev/tty

    local i=1
    local node gpu_model gpu_count
    for node in "${NODE_LIST[@]}"; do
        gpu_model="$(get_node_label "$node" "$LABEL_GPU_PRODUCT")"
        gpu_count="$(get_node_label "$node" "$LABEL_GPU_COUNT")"
        printf "  %d) %s  (%s, %s GPUs)\n" "$i" "$node" "$gpu_model" "$gpu_count" >/dev/tty
        (( i++ ))
    done

    echo "" >/dev/tty
    printf "Enter number (or 0 to cancel): " >/dev/tty
    local choice
    # Read user input from /dev/tty (stdin may be redirected inside $())
    read -r choice </dev/tty

    # Restore TUI state
    tput civis >/dev/tty 2>/dev/null || true
    stty -echo -icanon 2>/dev/null || true

    # Validate choice -- only the selected node name goes to stdout
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#NODE_LIST[@]} )); then
        # Array is 0-indexed, user input is 1-indexed
        echo "${NODE_LIST[$(( choice - 1 ))]}"
    else
        echo ""
    fi
}

# Show detailed information for a specific node.
# Uses whiptail --msgbox or plain-text fallback.
#
# Arguments:
#   $1 - node_name
show_node_detail() {
    local node="$1"
    [[ -z "$node" ]] && return

    local gpu_model machine_type gpu_count mig_capable mig_strategy mig_config
    local cuda_driver

    gpu_model="$(get_node_label "$node" "$LABEL_GPU_PRODUCT")"
    machine_type="$(get_node_label "$node" "$LABEL_GPU_MACHINE")"
    gpu_count="$(get_node_label "$node" "$LABEL_GPU_COUNT")"
    mig_capable="$(get_node_label "$node" "$LABEL_MIG_CAPABLE")"
    mig_strategy="$(get_node_label "$node" "$LABEL_MIG_STRATEGY")"
    mig_config="$(get_node_label "$node" "$LABEL_MIG_CONFIG")"
    cuda_driver="$(get_node_label "$node" "$LABEL_CUDA_DRIVER")"

    # Build detail text
    local detail=""
    detail+="GPU Model      : ${gpu_model}\n"
    detail+="Machine Type   : ${machine_type}\n"
    detail+="Physical GPUs  : ${gpu_count}\n"
    detail+="MIG Capable    : ${mig_capable}\n"
    detail+="MIG Strategy   : ${mig_strategy}\n"
    detail+="MIG Config     : ${mig_config}\n"
    detail+="CUDA Driver    : ${cuda_driver}\n"
    detail+="\n"

    # Resource table (plain text for dialog)
    detail+="$(printf "%-24s  %7s  %8s  %11s\n" "Resource" "Total" "In-Use" "Available")\n"
    detail+="$(printf "%-24s  %7s  %8s  %11s\n" "------------------------" "-------" "--------" "-----------")\n"

    local res_type alloc inuse avail display_name
    for res_type in "${ALL_RESOURCE_TYPES[@]}"; do
        alloc="$(get_allocatable "$node" "$res_type")"
        inuse="$(get_inuse "$node" "$res_type")"
        avail=$(( alloc - inuse ))

        # Human-friendly name: "Whole GPU" or "MIG <profile>"
        if [[ "$res_type" == "$WHOLE_GPU_RESOURCE" ]]; then
            display_name="Whole GPU"
        else
            # Strip the GPU resource prefix + "mig-" -> "1g.35gb"
            display_name="MIG ${res_type#"${GPU_RESOURCE_PREFIX}mig-"}"
        fi

        if (( alloc == 0 )); then
            detail+="$(printf "%-24s  %7d  %8s  %11s\n" "$display_name" 0 "-" "-")\n"
        else
            detail+="$(printf "%-24s  %7d  %8d  %11d\n" "$display_name" "$alloc" "$inuse" "$avail")\n"
        fi
    done

    # MIG slice details from node labels (if any MIG profiles are configured)
    local mig_details=""
    local profile profile_short mem sms
    for profile in "${KNOWN_MIG_PROFILES[@]}"; do
        alloc="$(get_allocatable "$node" "$profile")"
        (( alloc == 0 )) && continue

        # Strip the full prefix to get the short profile name (e.g., "1g.35gb")
        profile_short="${profile#"${GPU_RESOURCE_PREFIX}mig-"}"
        mem="$(get_node_label "$node" "${GPU_RESOURCE_PREFIX}mig-${profile_short}.memory")"
        sms="$(get_node_label "$node" "${GPU_RESOURCE_PREFIX}mig-${profile_short}.multiprocessors")"

        if [[ "$mem" != "-" || "$sms" != "-" ]]; then
            mig_details+="MIG ${profile_short}  : ${sms} SMs, ${mem} MiB\n"
        fi
    done

    if [[ -n "$mig_details" ]]; then
        detail+="\nMIG Slice Details:\n${mig_details}"
    fi

    if [[ "$TUI_BACKEND" == "whiptail" ]]; then
        tput cnorm 2>/dev/null || true
        stty echo icanon 2>/dev/null || true

        # printf %b interprets \n escape sequences in $detail
        local detail_text
        printf -v detail_text "%b" "$detail"

        # Count content lines to compute dialog height dynamically.
        local line_count
        line_count="$(printf "%s" "$detail_text" | wc -l)"
        # Dialog chrome overhead: top/bottom border, title, padding, button row.
        local dialog_height=$(( line_count + 7 ))
        local scroll_flag=""

        # Only enable --scrolltext when content exceeds terminal height.
        # In many whiptail/newt builds, scroll mode repurposes the right column
        # for scrollbar rendering, so preserving non-scroll mode avoids the
        # "missing right border" look when content already fits.
        if (( dialog_height > TERM_ROWS - 2 )); then
            dialog_height=$(( TERM_ROWS - 2 ))
            scroll_flag="--scrolltext"
        fi

        # --fb = full-size buttons for consistent focus rendering.
        # $scroll_flag is intentionally unquoted: empty when not needed.
        whiptail --title "$node" --fb $scroll_flag --msgbox "$detail_text" "$dialog_height" 70

        tput civis 2>/dev/null || true
        stty -echo -icanon 2>/dev/null || true
    else
        tput cnorm 2>/dev/null || true
        stty echo icanon 2>/dev/null || true
        tput clear

        printf "=== %s ===\n\n" "$node"
        printf "%b" "$detail"
        echo ""
        printf "Press Enter to return to dashboard..."
        read -r

        tput civis 2>/dev/null || true
        stty -echo -icanon 2>/dev/null || true
    fi
}

# Show the help overlay with key bindings.
show_help() {
    local help_text=""
    help_text+="gpuctl - GPU Cluster Dashboard\n"
    help_text+="\n"
    help_text+="Key Bindings:\n"
    help_text+="─────────────────────────────\n"
    help_text+="R         Force refresh now\n"
    help_text+="N         Select node for detail view\n"
    help_text+="H / ?     Show this help\n"
    help_text+="Q / Esc   Quit\n"
    help_text+="\n"
    help_text+="The dashboard auto-refreshes every ${REFRESH_INTERVAL}s.\n"
    help_text+="Configure interval in:\n"
    help_text+="${GPUCTL_CONFIG_PATH}\n"

    if [[ "$TUI_BACKEND" == "whiptail" ]]; then
        tput cnorm 2>/dev/null || true
        stty echo icanon 2>/dev/null || true

        printf -v help_display "%b" "$help_text"
        # --fb = full-size buttons for consistent focus rendering.
        whiptail --title "Help" --fb --msgbox "$help_display" 18 50

        tput civis 2>/dev/null || true
        stty -echo -icanon 2>/dev/null || true
    else
        tput cnorm 2>/dev/null || true
        stty echo icanon 2>/dev/null || true
        tput clear

        printf "%b" "$help_text"
        echo ""
        printf "Press Enter to return to dashboard..."
        read -r

        tput civis 2>/dev/null || true
        stty -echo -icanon 2>/dev/null || true
    fi
}
