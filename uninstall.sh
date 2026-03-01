#!/bin/bash
# ============================================================================
# gpuctl Uninstaller - Remove gpuctl from the system
# ============================================================================
# Removes the gpuctl binary and configuration directory after prompting
# for confirmation.  Must be run as root.  Prints instructions for manual
# sudoers cleanup (does NOT modify sudoers automatically).
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly INSTALL_BIN="/usr/local/bin/gpuctl"
readonly INSTALL_LIB_DIR="/usr/local/lib/gpuctl"
readonly CONFIG_DIR="/etc/gpuctl"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Print an error message to stderr and exit
die() {
    echo "Error: $*" >&2
    exit 1
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

main() {
    echo "gpuctl Uninstaller"
    echo "=================="
    echo ""

    # Require root (UNINST-01)
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo bash uninstall.sh"
    fi

    # Show what will be removed
    echo "The following will be removed:"
    local has_files=false

    if [[ -f "$INSTALL_BIN" ]]; then
        echo "  - ${INSTALL_BIN}"
        has_files=true
    fi
    if [[ -d "$INSTALL_LIB_DIR" ]]; then
        echo "  - ${INSTALL_LIB_DIR}/ (and all contents)"
        has_files=true
    fi
    if [[ -d "$CONFIG_DIR" ]]; then
        echo "  - ${CONFIG_DIR}/ (and all contents)"
        has_files=true
    fi

    if [[ "$has_files" == false ]]; then
        echo "  (nothing found -- gpuctl does not appear to be installed)"
        echo ""
        echo "No action taken."
        exit 0
    fi

    # Prompt for confirmation (UNINST-04)
    echo ""
    printf "Proceed with uninstallation? [y/N]: "
    local response
    read -r response

    # ${response,,} converts to lowercase for case-insensitive comparison
    case "${response,,}" in
        y|yes) ;;
        *)
            echo "Uninstallation cancelled."
            exit 0
            ;;
    esac

    echo ""
    echo "Removing gpuctl..."

    # Remove the installed binary (UNINST-02)
    local actions_taken=()
    if [[ -f "$INSTALL_BIN" ]]; then
        rm -f "$INSTALL_BIN"
        actions_taken+=("Removed: ${INSTALL_BIN}")
        echo "  ${actions_taken[-1]}"
    fi

    # Remove the library directory and contents
    if [[ -d "$INSTALL_LIB_DIR" ]]; then
        rm -rf "$INSTALL_LIB_DIR"
        actions_taken+=("Removed: ${INSTALL_LIB_DIR}/")
        echo "  ${actions_taken[-1]}"
    fi

    # Remove the config directory and contents (UNINST-03)
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        actions_taken+=("Removed: ${CONFIG_DIR}/")
        echo "  ${actions_taken[-1]}"
    fi

    echo ""

    # Summary of actions (UNINST-06)
    echo "============================================"
    echo "  Uninstallation Summary"
    echo "============================================"
    echo ""

    local action
    for action in "${actions_taken[@]}"; do
        echo "  [done] ${action}"
    done
    echo ""

    # Sudoers removal instructions (UNINST-05)
    echo "MANUAL STEP: Sudoers Cleanup"
    echo "----------------------------"
    echo "If you configured a sudoers entry for gpuctl, remove it manually:"
    echo ""
    echo "  sudo rm /etc/sudoers.d/gpuctl"
    echo ""
    echo "This step is intentionally manual for security reasons."
    echo ""
    echo "Uninstallation complete."
}

main "$@"
