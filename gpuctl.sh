#!/bin/bash
# ============================================================================
# gpuctl - NVIDIA GPU Cluster Resource Dashboard
# ============================================================================
# Discovers GPU configurations (whole GPUs and MIG slices) and their
# availability across Kubernetes worker nodes in an NVIDIA DGX cluster.
# Provides both an interactive TUI dashboard (ANSI + whiptail dialogs) and
# a plain-text CLI mode for scripting/piping.
#
# Runs from the BCM head/login node with elevated privileges via sudoers.
# Only executes read-only kubectl operations; output never exposes pod names,
# namespaces, user identities, or workload metadata.
#
# This is the main orchestrator script.  Functional modules live in lib/.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# -e = exit on error, -u = treat unset vars as error, -o pipefail = pipe fails
# on first non-zero exit.  Together they prevent silent failures.
set -euo pipefail

# ============================================================================
# LIBRARY PATH DETECTION
# ============================================================================

# readlink -f resolves symlinks to get the canonical path of this script,
# then dirname + cd/pwd extracts the absolute directory.
_GPUCTL_SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Dual-mode: development (lib/ next to script) vs. installed (/usr/local/lib/gpuctl)
if [[ -d "${_GPUCTL_SCRIPT_DIR}/lib" ]]; then
    readonly GPUCTL_LIB="${_GPUCTL_SCRIPT_DIR}/lib"
else
    readonly GPUCTL_LIB="/usr/local/lib/gpuctl"
fi

# ============================================================================
# SAFE SOURCE
# ============================================================================

# Safely source a library file with ownership and permission validation.
# Since gpuctl runs as root via sudoers, sourced files must be trusted to
# prevent privilege escalation through tampered library files.
#
# When running as non-root (development mode), ownership checks are skipped.
#
# Arguments:
#   $1 - file_path: Absolute path to the library file to source
#
# Returns:
#   0 on success (file sourced)
#   Exits with error if file is missing, not owned by root, or world-writable
safe_source() {
    local file_path="$1"

    if [[ ! -f "$file_path" ]]; then
        echo "Error: Required library not found: ${file_path}" >&2
        echo "       gpuctl may not be installed correctly.  Try reinstalling." >&2
        exit 1
    fi

    # id -u returns the effective user ID; 0 = root
    if (( $(id -u) == 0 )); then
        local file_owner file_perms

        # stat -c %u = numeric owner UID; stat -c %a = octal permissions
        file_owner="$(stat -c %u "$file_path" 2>/dev/null)" || file_owner=""
        file_perms="$(stat -c %a "$file_path" 2>/dev/null)" || file_perms=""

        if [[ "$file_owner" != "0" ]]; then
            echo "Error: Library file not owned by root: ${file_path}" >&2
            echo "       This is a security risk.  Fix with: sudo chown root:root ${file_path}" >&2
            exit 1
        fi

        # Check world-writable bit.  Octal permissions ending in 2, 3, 6, or 7
        # have the world-write bit set.  We check the last digit.
        # ${file_perms: -1} extracts the last character of the permissions string.
        local world_bits="${file_perms: -1}"
        if [[ "$world_bits" == "2" || "$world_bits" == "3" || \
              "$world_bits" == "6" || "$world_bits" == "7" ]]; then
            echo "Error: Library file is world-writable: ${file_path}" >&2
            echo "       This is a security risk.  Fix with: sudo chmod o-w ${file_path}" >&2
            exit 1
        fi
    fi

    # shellcheck source=/dev/null
    source "$file_path"
}

# ============================================================================
# SOURCE LIBRARIES
# ============================================================================
# Order matters: each module may depend on symbols from earlier modules.

safe_source "${GPUCTL_LIB}/config.sh"        # Constants, defaults, load_config()
safe_source "${GPUCTL_LIB}/helpers.sh"        # die(), parse_args(), preflight_checks()
safe_source "${GPUCTL_LIB}/data.sh"           # kubectl data collection and aggregation
safe_source "${GPUCTL_LIB}/cli.sh"            # Plain-text CLI output
safe_source "${GPUCTL_LIB}/tui_core.sh"       # Colors, box-drawing, terminal management
safe_source "${GPUCTL_LIB}/tui_draw.sh"       # Dashboard drawing functions
safe_source "${GPUCTL_LIB}/tui_dialogs.sh"    # Interactive dialog windows

# ============================================================================
# MAIN LOOP
# ============================================================================

# Handle a single keypress from the user.
#
# Arguments:
#   $1 - key: the character read from stdin
#
# Returns:
#   0 - continue running
#   1 - quit requested
handle_keypress() {
    local key="$1"

    # ${key,,} converts to lowercase for case-insensitive matching
    case "${key,,}" in
        r)
            # Force immediate refresh
            return 0
            ;;
        n)
            # Node detail view
            local selected
            selected="$(show_node_selector)"
            if [[ -n "$selected" ]]; then
                show_node_detail "$selected"
            fi
            return 0
            ;;
        h|\?)
            show_help
            return 0
            ;;
        q)
            return 1
            ;;
        $'\e')
            # Escape key (raw byte 0x1B) -- quit
            return 1
            ;;
    esac

    return 0
}

# Main TUI loop: fetch data, draw dashboard, wait for keypress or countdown.
#
# Implements the refresh cycle described in TUI_DESIGN.md Section 6.1:
# 1. Fetch data
# 2. Render dashboard
# 3. Countdown with keypress detection
# 4. Repeat on expiry or keypress
main_loop() {
    local first_draw=true

    while true; do
        # Fetch/refresh data
        if ! refresh_data; then
            cleanup_terminal
            echo "No GPU-enabled worker nodes found in the cluster."
            exit 0
        fi

        # Clear screen on first draw only; subsequent draws use tput cup 0 0
        if [[ "$first_draw" == true ]]; then
            tput clear
            first_draw=false
        fi

        NEEDS_REDRAW=false

        # Countdown loop: draw dashboard, wait 1 second, check for keypress
        local countdown="$REFRESH_INTERVAL"
        while (( countdown > 0 )); do
            # Redraw on resize
            if [[ "$NEEDS_REDRAW" == true ]]; then
                tput clear
                NEEDS_REDRAW=false
            fi

            draw_dashboard "$countdown"

            # read -t 1 = timeout after 1 second; -n 1 = read single character.
            # Returns non-zero on timeout (no input), which is expected.
            local key=""
            if read -t 1 -n 1 key 2>/dev/null; then
                if ! handle_keypress "$key"; then
                    return 0
                fi
                # After handling keypress (R, N, H), force refresh
                # ${key,,} = convert to lowercase for case-insensitive match
                if [[ "${key,,}" == "r" ]]; then
                    break
                fi
                # After dialog return, force redraw
                tput clear
                first_draw=false
            else
                # Defense-in-depth: if read returns instantly (e.g., stdin is
                # unexpectedly non-blocking), sleep prevents busy-spinning.
                # Under normal TTY operation, read -t 1 already sleeps 1 second.
                sleep 1
            fi

            (( countdown-- ))
        done
    done
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

main() {
    # Load config first (lowest priority), then parse CLI args (highest priority)
    load_config
    parse_args "$@"

    # Run pre-flight checks
    preflight_checks

    # Route to the appropriate output mode
    if [[ "$OUTPUT_MODE" == "cli" ]]; then
        # CLI mode: one-shot snapshot, no TUI (FR-18)
        if ! refresh_data; then
            echo "No GPU-enabled worker nodes found in the cluster."
            exit 0
        fi
        print_cli_output
        exit 0
    fi

    # TUI mode requires an interactive terminal for keypress handling.
    # [[ -t 0 ]] tests if file descriptor 0 (stdin) is a terminal (TTY).
    # Non-interactive stdin (pipe, redirect, /dev/null) causes `read` to
    # return immediately, which would busy-spin the refresh loop.
    if [[ ! -t 0 ]]; then
        echo "Warning: Non-interactive stdin detected. Falling back to CLI mode." >&2
        if ! refresh_data; then
            echo "No GPU-enabled worker nodes found in the cluster."
            exit 0
        fi
        print_cli_output
        exit 0
    fi

    # TUI mode: interactive dashboard
    detect_terminal_capabilities

    # If terminal is too narrow, warn and fall back to CLI
    if (( TERM_COLS < 80 )); then
        echo "Warning: Terminal too narrow (${TERM_COLS} cols). Falling back to CLI mode." >&2
        if ! refresh_data; then
            echo "No GPU-enabled worker nodes found in the cluster."
            exit 0
        fi
        print_cli_output
        exit 0
    fi

    init_colors
    init_terminal
    main_loop
}

main "$@"
