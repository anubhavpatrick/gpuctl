# ============================================================================
# gpuctl/tui_core - TUI Colors, Box-Drawing, and Terminal Management
# ============================================================================
# Provides color/attribute escape sequences, Unicode box-drawing character
# sets (with ASCII fallback), and terminal lifecycle management for the
# interactive dashboard (alternate screen buffer, cursor hiding, signal
# traps for clean restoration on exit).
#
# Sourced by the main gpuctl script.  Do not execute directly.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# ============================================================================
# TUI COLOR PRIMITIVES
# ============================================================================

# Terminal color/attribute escape sequences (populated by init_colors)
C_RESET=""
C_BOLD=""
C_DIM=""
C_HEADER_FG=""
C_HEADER_BG=""
C_BORDER=""
C_NODE_NAME=""
C_GPU_MODEL=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_GRAY=""
C_FOOTER_FG=""
C_FOOTER_BG=""
C_REFRESH=""

# Box-drawing characters (Unicode with ASCII fallback)
BOX_TL="" BOX_TR="" BOX_BL="" BOX_BR=""
BOX_H="" BOX_V=""
BOX_LT="" BOX_RT="" BOX_TT="" BOX_BT="" BOX_X=""

# Initialize color variables and box-drawing characters based on terminal
# capabilities.  Must be called after detect_terminal_capabilities().
init_colors() {
    if (( TERM_COLORS >= 8 )); then
        C_RESET="$(tput sgr0)"
        C_BOLD="$(tput bold)"
        C_DIM="$(tput dim 2>/dev/null || true)"
        # setaf = set ANSI foreground; setab = set ANSI background
        C_HEADER_FG="$(tput bold)$(tput setaf 7)"          # Bold white
        C_HEADER_BG="$(tput setab 4)"                       # Blue background
        C_BORDER="$(tput setaf 2)"                           # Green (NVIDIA brand)
        C_NODE_NAME="$(tput bold)$(tput setaf 7)"           # Bold white
        C_GPU_MODEL="$(tput setaf 5)"                        # Magenta
        C_GREEN="$(tput bold)$(tput setaf 2)"               # Bold green
        C_YELLOW="$(tput setaf 3)"                           # Yellow
        C_RED="$(tput bold)$(tput setaf 1)"                 # Bold red
        C_GRAY="$(tput setaf 8 2>/dev/null || tput dim)"    # Dark gray (may not exist)
        C_FOOTER_FG="$(tput setaf 0)"                        # Black
        C_FOOTER_BG="$(tput setab 7)"                        # White background
        C_REFRESH="$(tput setaf 2)"                          # Green (NVIDIA brand)

        # NEWT_COLORS controls whiptail dialog theming. Format is
        # "widget=fg,bg:widget=fg,bg:..." where each entry sets the
        # foreground/background pair for a UI element.
        # Default newt theme uses pink/magenta background; override to
        # black background with green accents matching the NVIDIA brand.
        #
        # Single-line colon-separated format avoids whitespace parsing
        # ambiguity in some newt/whiptail builds.
        #
        # Key entries:
        #   actsellistbox = highlighted item in a focused listbox (fixes
        #                   default pink by overriding to white-on-green)
        #   sellistbox    = selected item in an unfocused listbox
        #   button/actbutton/compactbutton = some whiptail/newt builds render
        #                   dialog buttons with standard button widgets, while
        #                   others use compact button variants. We assign
        #                   explicit inactive vs active colors to both paths so
        #                   Tab focus remains visible on all supported dialogs.
        #   acttextbox    = focused textbox background
        export NEWT_COLORS='root=white,black:border=green,black:window=white,black:shadow=white,black:title=green,black:button=black,white:actbutton=black,green:compactbutton=black,green:listbox=black,white:actlistbox=white,green:sellistbox=black,white:actsellistbox=white,green:textbox=white,black:acttextbox=white,black:label=white,black:helpline=white,black'
    fi

    if [[ "$HAS_UNICODE" == true ]]; then
        BOX_TL="┌" BOX_TR="┐" BOX_BL="└" BOX_BR="┘"
        BOX_H="─" BOX_V="│"
        BOX_LT="├" BOX_RT="┤" BOX_TT="┬" BOX_BT="┴" BOX_X="┼"
    else
        BOX_TL="+" BOX_TR="+" BOX_BL="+" BOX_BR="+"
        BOX_H="-" BOX_V="|"
        BOX_LT="+" BOX_RT="+" BOX_TT="+" BOX_BT="+" BOX_X="+"
    fi
}

# Apply color to an availability value based on status.
# Green = fully free, Yellow = partially used, Red = fully consumed,
# Gray = not configured (allocatable = 0).
#
# Arguments:
#   $1 - allocatable count
#   $2 - inuse count
#   $3 - available count (or "-" for not configured)
#   $4 - width: field width for printf (default 5)
#
# Returns (stdout):
#   Colorized string of the available value
color_available() {
    local alloc="$1" inuse="$2" avail="$3"
    # ${4:-5} = use caller-supplied width, or default to 5
    local width="${4:-5}"

    if (( alloc == 0 )); then
        # Not configured -- show dash in gray
        # %*s = right-justify to $width characters
        printf "%s%*s%s" "$C_GRAY" "$width" "-" "$C_RESET"
    elif (( avail == 0 )); then
        # Fully consumed
        printf "%s%*d%s" "$C_RED" "$width" "$avail" "$C_RESET"
    elif (( inuse > 0 )); then
        # Partially used
        printf "%s%*d%s" "$C_YELLOW" "$width" "$avail" "$C_RESET"
    else
        # Fully free
        printf "%s%*d%s" "$C_GREEN" "$width" "$avail" "$C_RESET"
    fi
}

# ============================================================================
# TUI TERMINAL MANAGEMENT
# ============================================================================

# Flag to track whether terminal has been initialized (for safe cleanup)
TUI_INITIALIZED=false

# Initialize terminal for TUI mode.
# Enters alternate screen buffer, hides cursor, disables echo.
# `trap` registers cleanup to run on script exit or signals.
#
# Side effects:
#   - Modifies terminal state (alternate buffer, cursor hidden, no echo)
#   - Registers cleanup trap for EXIT, INT, TERM, HUP signals
init_terminal() {
    TUI_INITIALIZED=true

    # tput smcup = enter alternate screen buffer (preserves user's scrollback)
    tput smcup 2>/dev/null || true
    # tput civis = make cursor invisible
    tput civis 2>/dev/null || true
    # stty -echo = disable echoing typed characters
    # stty -icanon = disable canonical (line-buffered) mode so we can read
    # single characters immediately
    stty -echo -icanon 2>/dev/null || true

    # trap registers cleanup_terminal to run on these signals:
    # EXIT = normal exit, INT = Ctrl+C, TERM = kill, HUP = terminal closed
    trap cleanup_terminal EXIT INT TERM HUP

    # SIGWINCH is sent when the terminal is resized
    trap handle_resize WINCH
}

# Restore terminal to its original state.  Called by trap on exit/signals.
# Safe to call multiple times.
#
# Side effects:
#   - Restores cursor visibility, echo, canonical mode, screen buffer
cleanup_terminal() {
    [[ "$TUI_INITIALIZED" == true ]] || return 0
    TUI_INITIALIZED=false

    # tput cnorm = restore normal (visible) cursor
    tput cnorm 2>/dev/null || true
    # tput rmcup = leave alternate screen buffer (restores user's prior screen)
    tput rmcup 2>/dev/null || true
    # Restore echo and canonical mode
    stty echo icanon 2>/dev/null || true

    echo ""
}

# Handle terminal resize (SIGWINCH).
# Re-detect terminal dimensions and set a flag to force full redraw.
NEEDS_REDRAW=false

handle_resize() {
    TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
    TERM_ROWS="$(tput lines 2>/dev/null || echo 24)"
    NEEDS_REDRAW=true
}
