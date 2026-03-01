# ============================================================================
# gpuctl/tui_draw - TUI Dashboard Drawing Functions
# ============================================================================
# Renders the interactive dashboard frame: header with title and refresh
# timer, cluster-wide summary table, per-node resource tables with
# box-drawing borders, and a footer bar with key bindings.
#
# Sourced by the main gpuctl script.  Do not execute directly.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# ============================================================================
# TUI DRAWING FUNCTIONS
# ============================================================================

# Draw a horizontal line spanning the terminal width.
# Used for top/bottom borders and section separators.
#
# Arguments:
#   $1 - left_char  (e.g., BOX_TL for top border)
#   $2 - fill_char  (e.g., BOX_H)
#   $3 - right_char (e.g., BOX_TR for top border)
draw_hline() {
    local left="$1" fill="$2" right="$3"
    local inner_width
    # inner width = total - 2 border chars
    inner_width=$(( TERM_COLS - 2 ))
    (( inner_width < 0 )) && inner_width=0

    local line="$left"
    local i
    for (( i = 0; i < inner_width; i++ )); do
        line+="$fill"
    done
    line+="$right"

    printf "%s%s%s\n" "$C_BORDER" "$line" "$C_RESET"
}

# Draw a text line padded to terminal width with vertical borders.
#
# Arguments:
#   $1 - text content (may include color escapes)
#   $2 - visible_length: actual visible character count (excluding escapes)
draw_bordered_line() {
    local text="$1" visible_len="$2"
    local inner_width
    inner_width=$(( TERM_COLS - 2 ))
    (( inner_width < 0 )) && inner_width=0

    local pad_len
    pad_len=$(( inner_width - visible_len ))
    (( pad_len < 0 )) && pad_len=0

    # printf "%-*s" pads a string to a minimum width with spaces
    printf "%s%s%s%s%-*s%s%s%s\n" \
        "$C_BORDER" "$BOX_V" "$C_RESET" \
        "$text" \
        "$pad_len" "" \
        "$C_BORDER" "$BOX_V" "$C_RESET"
}

# Draw an empty bordered line (just borders + spaces)
draw_empty_line() {
    draw_bordered_line "" 0
}

# Draw the dashboard header: title bar and refresh timestamp.
#
# Arguments:
#   $1 - countdown: seconds until next refresh
draw_header() {
    local countdown="$1"
    local title="gpuctl - GPU Cluster Dashboard"
    local timestamp
    timestamp="$(date '+%H:%M:%S %Z')"
    local refresh_info="Last refreshed: ${timestamp}  [Auto: ${REFRESH_INTERVAL}s]"

    # Top border
    draw_hline "$BOX_TL" "$BOX_H" "$BOX_TR"

    # Title line -- centered
    local inner_width
    inner_width=$(( TERM_COLS - 2 ))
    local title_len=${#title}
    local title_pad
    # Center by computing left padding
    title_pad=$(( (inner_width - title_len) / 2 ))
    (( title_pad < 0 )) && title_pad=0

    local title_line
    # printf "%*s" with just width and empty string produces that many spaces
    title_line="$(printf "%*s" "$title_pad" "")${C_HEADER_FG}${C_HEADER_BG}${title}${C_RESET}"
    # Pass actual visible length (left padding + title) so draw_bordered_line
    # computes correct right padding to align the border character.
    draw_bordered_line "$title_line" "$(( title_pad + title_len ))"

    # Refresh info line -- centered
    local ref_len=${#refresh_info}
    local ref_pad
    ref_pad=$(( (inner_width - ref_len) / 2 ))
    (( ref_pad < 0 )) && ref_pad=0

    local ref_line
    ref_line="$(printf "%*s" "$ref_pad" "")${C_REFRESH}${refresh_info}${C_RESET}"
    # Pass actual visible length (left padding + text) for correct right padding
    draw_bordered_line "$ref_line" "$(( ref_pad + ref_len ))"

    # Separator
    draw_hline "$BOX_LT" "$BOX_H" "$BOX_RT"
}

# Draw the cluster-wide summary section.
draw_cluster_summary() {
    local inner_width
    inner_width=$(( TERM_COLS - 2 ))

    # ${#NODE_LIST[@]} = number of GPU nodes
    local node_count="${#NODE_LIST[@]}"
    local label="  CLUSTER SUMMARY"
    local node_info="Nodes: ${node_count}"
    local label_len=${#label}
    local info_len=${#node_info}
    local gap
    gap=$(( inner_width - label_len - info_len - 2 ))
    (( gap < 0 )) && gap=1

    local header_text
    header_text="${C_BOLD}${label}${C_RESET}$(printf "%*s" "$gap" "")${node_info}"
    draw_bordered_line "$header_text" "$inner_width"

    # Thin separator
    local sep_line="  "
    local sep_i
    for (( sep_i = 0; sep_i < inner_width - 4; sep_i++ )); do
        sep_line+="$BOX_H"
    done
    draw_bordered_line "${C_BORDER}${sep_line}${C_RESET}" "$inner_width"

    # Determine column layout based on terminal width
    local res_col_w=28 total_w=11 inuse_w=10 avail_w=11
    local prefix_style="full"
    if (( TERM_COLS < 100 )); then
        res_col_w=22
        total_w=7
        inuse_w=8
        avail_w=7
        prefix_style="short"
    fi

    # Column headers
    local hdr_res="Resource" hdr_total="Total" hdr_inuse="In-Use" hdr_avail="Available"
    if [[ "$prefix_style" == "short" ]]; then
        hdr_avail="Avail"
    fi

    local hdr_line
    hdr_line="$(printf "  %-${res_col_w}s  %${total_w}s  %${inuse_w}s  %${avail_w}s" \
        "$hdr_res" "$hdr_total" "$hdr_inuse" "$hdr_avail")"
    draw_bordered_line "$hdr_line" "${#hdr_line}"

    # Resource rows (skip zero-total for cluster summary)
    local res_type c_alloc c_inuse c_avail display_name
    for res_type in "${ALL_RESOURCE_TYPES[@]}"; do
        c_alloc="${CLUSTER_ALLOC[$res_type]:-0}"
        c_inuse="${CLUSTER_INUSE[$res_type]:-0}"
        c_avail=$(( c_alloc - c_inuse ))

        (( c_alloc == 0 )) && continue

        display_name="$res_type"
        if [[ "$prefix_style" == "short" ]]; then
            # Remove the GPU resource prefix for compact display
            display_name="${res_type#"$GPU_RESOURCE_PREFIX"}"
        fi

        local avail_colored
        avail_colored="$(color_available "$c_alloc" "$c_inuse" "$c_avail" "$avail_w")"

        local row_plain
        row_plain="$(printf "  %-${res_col_w}s  %${total_w}d  %${inuse_w}d  %${avail_w}s" \
            "$display_name" "$c_alloc" "$c_inuse" "")"
        local row_colored
        row_colored="$(printf "  %-${res_col_w}s  %${total_w}d  %${inuse_w}d  " \
            "$display_name" "$c_alloc" "$c_inuse")${avail_colored}"

        # Visible length is the plain text length (no color escapes)
        draw_bordered_line "$row_colored" "${#row_plain}"
    done

    draw_empty_line
    draw_hline "$BOX_LT" "$BOX_H" "$BOX_RT"
}

# Draw a single node section with its GPU info and resource table.
#
# Arguments:
#   $1 - node_name
draw_node_section() {
    local node="$1"
    local inner_width
    inner_width=$(( TERM_COLS - 2 ))

    local gpu_model machine_type gpu_count mig_strategy
    gpu_model="$(get_node_label "$node" "$LABEL_GPU_PRODUCT")"
    machine_type="$(get_node_label "$node" "$LABEL_GPU_MACHINE")"
    gpu_count="$(get_node_label "$node" "$LABEL_GPU_COUNT")"
    mig_strategy="$(get_node_label "$node" "$LABEL_MIG_STRATEGY")"

    draw_empty_line

    # Node info header line
    local prefix_style="full"
    if (( TERM_COLS < 100 )); then
        prefix_style="short"
    fi

    local info_line
    if [[ "$prefix_style" == "full" ]]; then
        info_line="  ${C_NODE_NAME}NODE: ${node}${C_RESET}"
        info_line+="      ${C_GPU_MODEL}GPU: ${gpu_model}${C_RESET}"
        info_line+="    Machine: ${machine_type}"
        local plain_info="  NODE: ${node}      GPU: ${gpu_model}    Machine: ${machine_type}"
    else
        info_line="  ${C_NODE_NAME}NODE: ${node}${C_RESET}  ${C_GPU_MODEL}${gpu_model}${C_RESET} (${machine_type})"
        local plain_info="  NODE: ${node}  ${gpu_model} (${machine_type})"
    fi
    draw_bordered_line "$info_line" "${#plain_info}"

    # MIG / GPU count sub-line
    local mig_status="disabled"
    if [[ "$mig_strategy" != "-" && "$mig_strategy" != "none" ]]; then
        mig_status="enabled (${mig_strategy})"
    fi
    local sub_line
    sub_line="$(printf "  MIG: %-24s Physical GPUs: %s" "$mig_status" "$gpu_count")"
    draw_bordered_line "$sub_line" "${#sub_line}"

    # Resource table
    local res_col_w=28 total_w=7 inuse_w=8 avail_w=11
    local hdr_avail="Available"
    if [[ "$prefix_style" == "short" ]]; then
        res_col_w=22
        total_w=7
        inuse_w=8
        avail_w=7
        hdr_avail="Avail"
    fi

    # Table header with box borders
    local tbl_inner
    tbl_inner=$(( res_col_w + total_w + inuse_w + avail_w + 9 ))

    local tbl_top="  ${BOX_TL}"
    local ii
    for (( ii = 0; ii < res_col_w + 2; ii++ )); do tbl_top+="$BOX_H"; done
    tbl_top+="${BOX_TT}"
    for (( ii = 0; ii < total_w + 2; ii++ )); do tbl_top+="$BOX_H"; done
    tbl_top+="${BOX_TT}"
    for (( ii = 0; ii < inuse_w + 2; ii++ )); do tbl_top+="$BOX_H"; done
    tbl_top+="${BOX_TT}"
    for (( ii = 0; ii < avail_w + 2; ii++ )); do tbl_top+="$BOX_H"; done
    tbl_top+="${BOX_TR}"
    draw_bordered_line "${C_BORDER}${tbl_top}${C_RESET}" "${#tbl_top}"

    # Column headers
    local col_hdr
    col_hdr="$(printf "  %s %-${res_col_w}s %s %${total_w}s %s %${inuse_w}s %s %${avail_w}s %s" \
        "$BOX_V" "Resource" "$BOX_V" "Total" "$BOX_V" "In-Use" "$BOX_V" "$hdr_avail" "$BOX_V")"
    draw_bordered_line "${C_BORDER}${col_hdr}${C_RESET}" "${#col_hdr}"

    # Header separator
    local tbl_sep="  ${BOX_LT}"
    for (( ii = 0; ii < res_col_w + 2; ii++ )); do tbl_sep+="$BOX_H"; done
    tbl_sep+="${BOX_X}"
    for (( ii = 0; ii < total_w + 2; ii++ )); do tbl_sep+="$BOX_H"; done
    tbl_sep+="${BOX_X}"
    for (( ii = 0; ii < inuse_w + 2; ii++ )); do tbl_sep+="$BOX_H"; done
    tbl_sep+="${BOX_X}"
    for (( ii = 0; ii < avail_w + 2; ii++ )); do tbl_sep+="$BOX_H"; done
    tbl_sep+="${BOX_RT}"
    draw_bordered_line "${C_BORDER}${tbl_sep}${C_RESET}" "${#tbl_sep}"

    # Resource rows
    local res_type alloc inuse avail display_name
    for res_type in "${ALL_RESOURCE_TYPES[@]}"; do
        alloc="$(get_allocatable "$node" "$res_type")"
        inuse="$(get_inuse "$node" "$res_type")"
        avail=$(( alloc - inuse ))

        display_name="$res_type"
        if [[ "$prefix_style" == "short" ]]; then
            # Remove the GPU resource prefix for compact display
            display_name="${res_type#"$GPU_RESOURCE_PREFIX"}"
        fi

        local inuse_display avail_colored
        if (( alloc == 0 )); then
            inuse_display="-"
            avail_colored="$(color_available 0 0 0 "$avail_w")"
        else
            inuse_display="$inuse"
            avail_colored="$(color_available "$alloc" "$inuse" "$avail" "$avail_w")"
        fi

        local row_plain
        row_plain="$(printf "  %s %-${res_col_w}s %s %${total_w}d %s %${inuse_w}s %s %${avail_w}s %s" \
            "$BOX_V" "$display_name" "$BOX_V" "$alloc" "$BOX_V" "$inuse_display" "$BOX_V" "" "$BOX_V")"
        local row_colored
        row_colored="$(printf "  %s %-${res_col_w}s %s %${total_w}d %s %${inuse_w}s %s " \
            "$BOX_V" "$display_name" "$BOX_V" "$alloc" "$BOX_V" "$inuse_display" "$BOX_V")${avail_colored}$(printf " %s" "$BOX_V")"

        draw_bordered_line "${C_BORDER}${row_colored}${C_RESET}" "${#row_plain}"
    done

    # Table bottom border
    local tbl_bot="  ${BOX_BL}"
    for (( ii = 0; ii < res_col_w + 2; ii++ )); do tbl_bot+="$BOX_H"; done
    tbl_bot+="${BOX_BT}"
    for (( ii = 0; ii < total_w + 2; ii++ )); do tbl_bot+="$BOX_H"; done
    tbl_bot+="${BOX_BT}"
    for (( ii = 0; ii < inuse_w + 2; ii++ )); do tbl_bot+="$BOX_H"; done
    tbl_bot+="${BOX_BT}"
    for (( ii = 0; ii < avail_w + 2; ii++ )); do tbl_bot+="$BOX_H"; done
    tbl_bot+="${BOX_BR}"
    draw_bordered_line "${C_BORDER}${tbl_bot}${C_RESET}" "${#tbl_bot}"

    draw_empty_line
    draw_hline "$BOX_LT" "$BOX_H" "$BOX_RT"
}

# Draw the footer bar with key bindings and countdown timer.
#
# Arguments:
#   $1 - countdown: seconds until next auto-refresh
draw_footer() {
    local countdown="$1"
    local inner_width
    inner_width=$(( TERM_COLS - 2 ))

    local keys="  [R] Refresh   [N] Node Detail   [H] Help   [Q] Quit"
    local timer="Refresh in: ${countdown}s  "
    local keys_len=${#keys}
    local timer_len=${#timer}
    local gap
    gap=$(( inner_width - keys_len - timer_len ))
    (( gap < 0 )) && gap=1

    local footer_text
    footer_text="${C_FOOTER_FG}${C_FOOTER_BG}${keys}$(printf "%*s" "$gap" "")${timer}${C_RESET}"
    draw_bordered_line "$footer_text" "$inner_width"

    draw_hline "$BOX_BL" "$BOX_H" "$BOX_BR"
}

# Draw the complete dashboard frame.
# Uses tput cup 0 0 for flicker-free in-place redraws.
#
# Arguments:
#   $1 - countdown: seconds until next auto-refresh
draw_dashboard() {
    local countdown="$1"

    # Move cursor to top-left for flicker-free overwrite
    tput cup 0 0

    # Check for narrow terminal
    if (( TERM_COLS < 80 )); then
        tput clear
        echo "Terminal too narrow (${TERM_COLS} cols). Minimum 80 columns recommended."
        echo "Falling back to CLI output."
        echo ""
        print_cli_output
        return
    fi

    local nodes_to_show=()
    if [[ -n "$FILTER_NODE" ]]; then
        nodes_to_show=( "$FILTER_NODE" )
    else
        nodes_to_show=( "${NODE_LIST[@]}" )
    fi

    draw_header "$countdown"

    # Cluster summary (skip when filtering to a single node)
    if [[ -z "$FILTER_NODE" ]]; then
        draw_cluster_summary
    fi

    # Per-node sections
    local node
    local nodes_shown=0
    local max_nodes_visible
    # Estimate: each node section ~12 lines; leave room for header (6) + footer (3)
    max_nodes_visible=$(( (TERM_ROWS - 9) / 12 ))
    (( max_nodes_visible < 1 )) && max_nodes_visible=1

    for node in "${nodes_to_show[@]}"; do
        (( nodes_shown >= max_nodes_visible )) && break
        draw_node_section "$node"
        # || true prevents set -e exit: (( 0++ )) returns 0, and (( 0 )) = exit code 1
        (( nodes_shown++ )) || true
    done

    # If some nodes were truncated, show indicator
    if (( nodes_shown < ${#nodes_to_show[@]} )); then
        local trunc_msg="  Showing ${nodes_shown} of ${#nodes_to_show[@]} nodes (terminal too short for all)"
        draw_bordered_line "${C_YELLOW}${trunc_msg}${C_RESET}" "${#trunc_msg}"
        draw_hline "$BOX_LT" "$BOX_H" "$BOX_RT"
    fi

    draw_footer "$countdown"

    # tput ed = clear from cursor to end of screen (removes leftover lines
    # from a previously taller render, e.g., after terminal resize)
    tput ed 2>/dev/null || true
}
