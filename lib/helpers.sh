# ============================================================================
# gpuctl/helpers - Utility Functions and Pre-flight Checks
# ============================================================================
# General-purpose helper functions (die, command_exists), user-facing
# output (show_version, show_usage), argument parsing, dependency
# verification, and terminal capability detection.
#
# Sourced by the main gpuctl script.  Do not execute directly.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Print an error message to stderr and exit with code 1
die() {
    echo "Error: $*" >&2
    exit 1
}

# Check if a command exists in PATH
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Display version information and exit
show_version() {
    echo "gpuctl version $GPUCTL_VERSION"
    exit 0
}

# Display usage/help information and exit
show_usage() {
    cat <<'USAGE'
gpuctl - NVIDIA GPU Cluster Resource Dashboard

Usage: gpuctl [OPTIONS]

Options:
  --cli, --text       Run in plain-text CLI mode (no TUI)
  --node <name>       Show GPU info for a specific worker node only
  --refresh <secs>    Override TUI refresh interval (seconds)
  --help, -h          Show this help message
  --version, -v       Show version information

Examples:
  sudo gpuctl                     # Launch interactive TUI dashboard
  sudo gpuctl --cli               # One-shot plain text output
  sudo gpuctl --cli --node worker # Show specific node only
  sudo gpuctl --refresh 60        # TUI with 60-second refresh
USAGE
    exit 0
}

# Parse command-line arguments.
# CLI args override both defaults and config file values (FR-21).
#
# Side effects:
#   - Sets OUTPUT_MODE, FILTER_NODE, REFRESH_INTERVAL globals
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cli|--text)
                OUTPUT_MODE="cli"
                shift
                ;;
            --node)
                [[ -n "${2:-}" ]] || die "--node requires a node name argument."
                FILTER_NODE="$2"
                shift 2
                ;;
            --refresh)
                [[ -n "${2:-}" ]] || die "--refresh requires a numeric argument."
                if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 > 0 )); then
                    REFRESH_INTERVAL="$2"
                else
                    die "--refresh must be a positive integer (got '$2')."
                fi
                shift 2
                ;;
            --help|-h)
                show_usage
                ;;
            --version|-v)
                show_version
                ;;
            *)
                die "Unknown option: $1. Run 'gpuctl --help' for usage."
                ;;
        esac
    done
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

# Verify all required dependencies are available and detect TUI backend.
# Exits with an actionable error message if critical deps are missing (NFR-14).
#
# Side effects:
#   - Sets TUI_BACKEND global ("whiptail" or "ansi")
#   - May downgrade OUTPUT_MODE to "cli" if no TUI backend is usable
preflight_checks() {
    # Required: kubectl
    if ! command_exists kubectl; then
        die "kubectl is not installed or not in PATH. Please install kubectl to use gpuctl."
    fi

    # Required: jq (for JSON parsing of kubectl output)
    if ! command_exists jq; then
        die "jq is not installed. Install it with: sudo apt install jq"
    fi

    # Verify Kubernetes API is reachable with a lightweight request
    if ! kubectl cluster-info >/dev/null 2>&1; then
        die "Unable to reach Kubernetes API. Check cluster status and kubeconfig."
    fi

    # Detect TUI backend: whiptail > ansi fallback (NFR-15)
    if command_exists whiptail; then
        TUI_BACKEND="whiptail"
    else
        TUI_BACKEND="ansi"
        if [[ "$OUTPUT_MODE" == "tui" ]]; then
            echo "Note: whiptail not found. Dialogs will use plain-text fallback." >&2
        fi
    fi
}

# Detect terminal capabilities for TUI rendering.
# Called only when OUTPUT_MODE is "tui".
#
# Side effects:
#   - Sets TERM_COLS, TERM_ROWS, TERM_COLORS, HAS_UNICODE globals
detect_terminal_capabilities() {
    TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
    TERM_ROWS="$(tput lines 2>/dev/null || echo 24)"
    TERM_COLORS="$(tput colors 2>/dev/null || echo 0)"

    # Heuristic for Unicode support: check if locale uses a UTF charset
    if locale charmap 2>/dev/null | grep -qi utf; then
        HAS_UNICODE=true
    else
        HAS_UNICODE=false
    fi
}
