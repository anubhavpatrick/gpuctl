#!/bin/bash
# ============================================================================
# gpuctl Installer - Install gpuctl to the system
# ============================================================================
# Copies gpuctl to /usr/local/bin, creates config directory, installs
# default configuration.  Must be run as root.  Prints sudoers setup
# instructions for the administrator (does NOT modify sudoers automatically).
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
readonly CONFIG_FILE="${CONFIG_DIR}/gpuctl.conf"
readonly SOURCE_SCRIPT="gpuctl.sh"
readonly SOURCE_LIB_DIR="lib"
readonly SOURCE_CONFIG="gpuctl.conf.example"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Print an error message to stderr and exit
die() {
    echo "Error: $*" >&2
    exit 1
}

# Check if a command exists in PATH
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

main() {
    echo "gpuctl Installer"
    echo "================"
    echo ""

    # Require root (INST-05)
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo bash install.sh"
    fi

    # Verify source files exist
    local script_dir
    # dirname extracts the directory part of a path; cd + pwd resolves it to
    # an absolute path even if the script was invoked with a relative path
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ ! -f "${script_dir}/${SOURCE_SCRIPT}" ]]; then
        die "Source script '${SOURCE_SCRIPT}' not found in ${script_dir}."
    fi
    if [[ ! -d "${script_dir}/${SOURCE_LIB_DIR}" ]]; then
        die "Library directory '${SOURCE_LIB_DIR}/' not found in ${script_dir}."
    fi
    if [[ ! -f "${script_dir}/${SOURCE_CONFIG}" ]]; then
        die "Example config '${SOURCE_CONFIG}' not found in ${script_dir}."
    fi

    # Check required dependencies (INST-04)
    echo "Checking dependencies..."
    local missing=()
    if ! command_exists kubectl; then
        missing+=("kubectl")
    fi
    if ! command_exists jq; then
        missing+=("jq (install with: sudo apt install jq)")
    fi

    # ${#missing[@]} = array length
    if (( ${#missing[@]} > 0 )); then
        echo "WARNING: The following required dependencies are missing:"
        local dep
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "gpuctl will not function correctly without these."
        echo ""
    else
        echo "  All required dependencies found."
    fi

    # Check optional dependency
    if ! command_exists whiptail; then
        echo "  Note: whiptail not found (optional). TUI dialogs will use plain-text fallback."
        echo "  Install with: sudo apt install whiptail"
    else
        echo "  whiptail found (TUI dialogs available)."
    fi
    echo ""

    # Install the script (INST-01, INST-02)
    echo "Installing gpuctl..."
    cp "${script_dir}/${SOURCE_SCRIPT}" "$INSTALL_BIN"
    chown root:root "$INSTALL_BIN"
    chmod 0755 "$INSTALL_BIN"
    echo "  Installed: ${INSTALL_BIN} (root:root, 0755)"

    # Install library modules
    mkdir -p "$INSTALL_LIB_DIR"
    chown root:root "$INSTALL_LIB_DIR"
    chmod 0755 "$INSTALL_LIB_DIR"
    echo "  Created: ${INSTALL_LIB_DIR}/ (root:root, 0755)"

    local lib_file
    for lib_file in "${script_dir}/${SOURCE_LIB_DIR}"/*.sh; do
        cp "$lib_file" "$INSTALL_LIB_DIR/"
        # basename extracts the filename from a full path
        local lib_name
        lib_name="$(basename "$lib_file")"
        chown root:root "${INSTALL_LIB_DIR}/${lib_name}"
        chmod 0644 "${INSTALL_LIB_DIR}/${lib_name}"
        echo "  Installed: ${INSTALL_LIB_DIR}/${lib_name} (root:root, 0644)"
    done

    # Create config directory and install config (INST-03)
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
        echo "  Created: ${CONFIG_DIR}/"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  Config file already exists: ${CONFIG_FILE} (preserved)"
    else
        cp "${script_dir}/${SOURCE_CONFIG}" "$CONFIG_FILE"
        chmod 0644 "$CONFIG_FILE"
        echo "  Installed: ${CONFIG_FILE} (0644)"
    fi
    echo ""

    # Print sudoers instructions (INST-06)
    echo "============================================"
    echo "  MANUAL STEP: Sudoers Configuration"
    echo "============================================"
    echo ""
    echo "To allow all users to run gpuctl without a password prompt,"
    echo "create a sudoers drop-in file:"
    echo ""
    echo "  sudo visudo -f /etc/sudoers.d/gpuctl"
    echo ""
    echo "Add the following line:"
    echo ""
    echo "  ALL ALL=(root) NOPASSWD: /usr/local/bin/gpuctl"
    echo ""
    echo "This step is intentionally manual for security reasons."
    echo ""

    echo "Installation complete."
    echo ""
    echo "Usage:"
    echo "  sudo gpuctl               # Interactive TUI dashboard"
    echo "  sudo gpuctl --cli         # One-shot plain text output"
    echo "  sudo gpuctl --help        # Show all options"
}

main "$@"
