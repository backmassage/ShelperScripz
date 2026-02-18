#!/usr/bin/env bash
# =============================================================================
# jellyfin-logs.sh — Jellyfin Journal / Log Viewer & Debugger
# For: Arch Linux, native Jellyfin package (systemd journal)
# Usage: ./jellyfin-logs.sh [OPTIONS]
# =============================================================================
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
JELLYFIN_SERVICE="jellyfin.service"
JELLYFIN_LOG_DIR="/var/lib/jellyfin/log"  # Jellyfin's own file-based logs

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*"; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_journal() {
    local lines="$1" priority="$2" since="$3" grep_pat="$4"

    header "Jellyfin Journal (systemd)"

    local args=(-u "$JELLYFIN_SERVICE" --no-pager)

    if [[ -n "$since" ]]; then
        args+=(--since "$since")
        info "Since: $since"
    else
        args+=(-n "$lines")
        info "Last $lines lines"
    fi

    if [[ -n "$priority" ]]; then
        args+=(-p "$priority")
        info "Priority: $priority"
    fi

    echo ""

    if [[ -n "$grep_pat" ]]; then
        info "Filter: $grep_pat"
        echo ""
        journalctl "${args[@]}" | grep -iE --color=always "$grep_pat" || \
            warn "No lines matched the filter"
    else
        journalctl "${args[@]}"
    fi
}

cmd_follow() {
    local priority="$1" grep_pat="$2"

    header "Following Jellyfin Journal (Ctrl+C to stop)"

    local args=(-u "$JELLYFIN_SERVICE" -f)

    if [[ -n "$priority" ]]; then
        args+=(-p "$priority")
        info "Priority: $priority"
    fi

    echo ""

    if [[ -n "$grep_pat" ]]; then
        info "Filter: $grep_pat"
        echo ""
        journalctl "${args[@]}" | grep -iE --color=always --line-buffered "$grep_pat"
    else
        journalctl "${args[@]}"
    fi
}

cmd_errors() {
    local since="$1"
    header "Jellyfin Errors & Warnings"

    local args=(-u "$JELLYFIN_SERVICE" --no-pager -p warning)

    if [[ -n "$since" ]]; then
        args+=(--since "$since")
        info "Since: $since"
    else
        args+=(-n 100)
        info "Last 100 entries"
    fi

    echo ""
    local output
    output=$(journalctl "${args[@]}" 2>/dev/null)

    if [[ -z "$output" ]]; then
        ok "No errors or warnings found"
    else
        echo "$output"
        echo ""
        local err_count warn_count
        err_count=$(echo "$output" | grep -ciE "error|err|fatal|exception|critical" || true)
        warn_count=$(echo "$output" | grep -ciE "warn" || true)
        info "Approximate: ${RED}${err_count} error lines${NC}, ${YELLOW}${warn_count} warning lines${NC}"
    fi
}

cmd_file_logs() {
    header "Jellyfin File-Based Logs"

    if [[ ! -d "$JELLYFIN_LOG_DIR" ]]; then
        warn "Log directory not found: $JELLYFIN_LOG_DIR"
        info "Jellyfin may only be logging to the systemd journal."
        info "Check your Jellyfin dashboard: Dashboard > Logs"
        return 0
    fi

    info "Log directory: $JELLYFIN_LOG_DIR"
    echo ""

    local log_files
    log_files=$(find "$JELLYFIN_LOG_DIR" -type f -name "*.log" 2>/dev/null | sort -r)

    if [[ -z "$log_files" ]]; then
        warn "No .log files found in $JELLYFIN_LOG_DIR"
        return 0
    fi

    printf "  ${BOLD}%-45s %10s  %s${NC}\n" "FILE" "SIZE" "MODIFIED"
    while IFS= read -r f; do
        local name size mod
        name=$(basename "$f")
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        mod=$(stat -c "%y" "$f" 2>/dev/null | cut -d'.' -f1)
        printf "  %-45s %10s  %s\n" "$name" "$size" "$mod"
    done <<< "$log_files"

    echo ""
    info "View a specific log file with:"
    echo "    less ${JELLYFIN_LOG_DIR}/<filename>"
}

cmd_read_file() {
    local target="$1" lines="$2" grep_pat="$3"
    header "Jellyfin Log File"

    if [[ ! -d "$JELLYFIN_LOG_DIR" ]]; then
        err "Log directory not found: $JELLYFIN_LOG_DIR"
        return 1
    fi

    local log_file=""

    if [[ "$target" == "latest" || -z "$target" ]]; then
        log_file=$(find "$JELLYFIN_LOG_DIR" -type f -name "*.log" -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [[ -z "$log_file" ]]; then
            err "No log files found"
            return 1
        fi
        info "Latest log: $(basename "$log_file")"
    elif [[ -f "$JELLYFIN_LOG_DIR/$target" ]]; then
        log_file="$JELLYFIN_LOG_DIR/$target"
    elif [[ -f "$target" ]]; then
        log_file="$target"
    else
        err "Log file not found: $target"
        info "Run '$0 files' to see available logs"
        return 1
    fi

    echo ""

    if [[ -n "$grep_pat" ]]; then
        info "Filter: $grep_pat (last $lines lines)"
        echo ""
        tail -n "$lines" "$log_file" | grep -iE --color=always "$grep_pat" || \
            warn "No lines matched the filter"
    else
        tail -n "$lines" "$log_file"
    fi
}

cmd_summary() {
    header "Jellyfin Log Summary"

    # Service status
    if systemctl is-active --quiet "$JELLYFIN_SERVICE"; then
        ok "Service: ${GREEN}running${NC}"
    else
        err "Service: ${RED}stopped${NC}"
    fi

    # Uptime / last restart
    local start_time
    start_time=$(systemctl show "$JELLYFIN_SERVICE" --property=ActiveEnterTimestamp --value 2>/dev/null)
    if [[ -n "$start_time" ]]; then
        info "Started: $start_time"
    fi

    # Recent error count
    echo ""
    info "Error counts by time window:"
    local periods=("1h" "6h" "24h" "7d")
    local labels=("Last hour" "Last 6 hours" "Last 24 hours" "Last 7 days")

    for i in "${!periods[@]}"; do
        local count
        count=$(journalctl -u "$JELLYFIN_SERVICE" --since "-${periods[$i]}" -p err --no-pager 2>/dev/null | grep -c "" || echo 0)
        # Subtract 1 for the header line journalctl may add
        (( count > 0 )) && count=$((count - 1))
        (( count < 0 )) && count=0

        local color="$GREEN"
        if (( count > 20 )); then color="$RED"
        elif (( count > 0 )); then color="$YELLOW"
        fi
        printf "  %-20s ${color}%d errors${NC}\n" "${labels[$i]}:" "$count"
    done

    # Most common error patterns (last 24h)
    header "Common Error Patterns (24h)"
    local error_lines
    error_lines=$(journalctl -u "$JELLYFIN_SERVICE" --since "-24h" -p err --no-pager 2>/dev/null | tail -n +2)
    if [[ -n "$error_lines" ]]; then
        echo "$error_lines" | \
            sed 's/^.*jellyfin\[[0-9]*\]: //' | \
            sort | uniq -c | sort -rn | head -10 | \
            awk '{count=$1; $1=""; printf "  %4dx %s\n", count, $0}'
    else
        ok "No errors in the last 24 hours"
    fi

    # Disk usage of logs
    header "Log Storage"
    local journal_size
    journal_size=$(journalctl -u "$JELLYFIN_SERVICE" --disk-usage 2>/dev/null | grep -oP '[\d.]+\s*[KMGT]' || echo "?")
    printf "  Journal usage:  %s\n" "$journal_size"

    if [[ -d "$JELLYFIN_LOG_DIR" ]]; then
        local file_size
        file_size=$(du -sh "$JELLYFIN_LOG_DIR" 2>/dev/null | cut -f1)
        printf "  File logs:      %s (%s)\n" "$file_size" "$JELLYFIN_LOG_DIR"
    fi
}

cmd_boot() {
    header "Jellyfin Logs Since Last Boot"
    journalctl -u "$JELLYFIN_SERVICE" -b --no-pager
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
${BOLD}Jellyfin Log Viewer & Debugger${NC}

${BOLD}Usage:${NC} $0 [command] [options]

${BOLD}Commands:${NC}
  journal              Show recent journal entries (default)
  follow               Live tail / follow the journal
  errors               Show only errors and warnings
  summary              Overview: error counts, patterns, storage
  boot                 Show all logs since last boot
  files                List Jellyfin's file-based logs
  read [file|latest]   Read a file-based log (default: latest)

${BOLD}Options:${NC}
  -n, --lines N        Number of lines to show (default: 50)
  -g, --grep PATTERN   Filter output by regex pattern
  -s, --since TIME     Show entries since TIME (e.g. "1 hour ago", "today")
  -p, --priority LVL   Journal priority: emerg,alert,crit,err,warning,notice,info,debug

${BOLD}Examples:${NC}
  $0                                  Last 50 journal lines
  $0 follow                           Live tail the journal
  $0 follow -g "error|fail"           Follow, filtering for errors
  $0 journal -n 200                   Last 200 journal lines
  $0 journal -s "1 hour ago"          Entries from the last hour
  $0 journal -g "transcode"           Search for transcoding messages
  $0 errors                           Errors & warnings (last 100)
  $0 errors -s today                  Today's errors
  $0 summary                          Error counts, patterns, storage
  $0 boot                             Everything since last boot
  $0 files                            List file-based logs
  $0 read latest -g "ffmpeg"          Search latest file log for ffmpeg

EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────

COMMAND=""
LINES=50
GREP_PAT=""
SINCE=""
PRIORITY=""
FILE_TARGET="latest"

while [[ $# -gt 0 ]]; do
    case "$1" in
        journal|follow|errors|summary|boot|files|read)
            COMMAND="$1"; shift ;;
        -n|--lines)   LINES="$2"; shift 2 ;;
        -g|--grep)    GREP_PAT="$2"; shift 2 ;;
        -s|--since)   SINCE="$2"; shift 2 ;;
        -p|--priority)PRIORITY="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "Unknown option: $1"; usage; exit 1 ;;
        *)
            # If command is 'read', next positional arg is the file target
            if [[ "$COMMAND" == "read" && -z "$FILE_TARGET" ]]; then
                FILE_TARGET="$1"
            elif [[ "$COMMAND" == "read" ]]; then
                FILE_TARGET="$1"
            fi
            shift ;;
    esac
done

COMMAND="${COMMAND:-journal}"

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$COMMAND" in
    journal)  cmd_journal "$LINES" "$PRIORITY" "$SINCE" "$GREP_PAT" ;;
    follow)   cmd_follow "$PRIORITY" "$GREP_PAT" ;;
    errors)   cmd_errors "$SINCE" ;;
    summary)  cmd_summary ;;
    boot)     cmd_boot ;;
    files)    cmd_file_logs ;;
    read)     cmd_read_file "$FILE_TARGET" "$LINES" "$GREP_PAT" ;;
    *)        err "Unknown command: $COMMAND"; usage; exit 1 ;;
esac
