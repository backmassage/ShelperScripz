#!/usr/bin/env bash
# =============================================================================
# jellyfin-manager.sh — Jellyfin Library Management Helper
# For: Arch Linux, native Jellyfin package (AUR/official)
# Usage: ./jellyfin-manager.sh [command]
# =============================================================================
set -euo pipefail

# ── Configuration (edit these to match your setup) ───────────────────────────
JELLYFIN_SERVICE="jellyfin.service"
MEDIA_ROOT="/mnt/media"                  # Root of your media library
JELLYFIN_DATA="/var/lib/jellyfin"        # Jellyfin data directory
JELLYFIN_LOG="/var/log/jellyfin"         # Jellyfin log directory
JELLYFIN_API_URL="http://localhost:8096" # Jellyfin API base URL
JELLYFIN_API_KEY=""                      # Set this for API-based scans (Settings > API Keys)

# Transcoding settings
TRANSCODE_DIR="/var/lib/jellyfin/transcodes"
TRANSCODE_WARN_GB=10  # Warn if transcode cache exceeds this size in GB

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*"; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_status() {
    header "Jellyfin Service Status"
    if systemctl is-active --quiet "$JELLYFIN_SERVICE"; then
        ok "Jellyfin is ${GREEN}running${NC}"
    else
        err "Jellyfin is ${RED}not running${NC}"
    fi
    echo ""
    systemctl status "$JELLYFIN_SERVICE" --no-pager -l 2>/dev/null | head -20

    header "Resource Usage"
    local pid
    pid=$(systemctl show "$JELLYFIN_SERVICE" --property=MainPID --value 2>/dev/null)
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        ps -p "$pid" -o pid,user,%cpu,%mem,rss,etime --no-headers 2>/dev/null | \
            awk '{printf "  PID: %s  User: %s  CPU: %s%%  MEM: %s%%  RSS: %.0f MB  Uptime: %s\n", $1, $2, $3, $4, $5/1024, $6}'
    else
        warn "Could not find Jellyfin PID"
    fi
}

cmd_scan() {
    header "Trigger Library Scan"
    if [[ -z "$JELLYFIN_API_KEY" ]]; then
        warn "No API key configured. Set JELLYFIN_API_KEY in the script."
        info "You can create one in Jellyfin: Dashboard > API Keys"
        info "Alternatively, restart Jellyfin to force a rescan:"
        echo "  sudo systemctl restart $JELLYFIN_SERVICE"
        return 1
    fi

    info "Requesting library scan via API..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${JELLYFIN_API_URL}/Library/Refresh" \
        -H "X-Emby-Token: ${JELLYFIN_API_KEY}")

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        ok "Library scan triggered successfully"
    else
        err "Failed to trigger scan (HTTP $http_code)"
        err "Check that Jellyfin is running and the API key is valid"
    fi
}

cmd_library() {
    header "Media Library Overview"
    if [[ ! -d "$MEDIA_ROOT" ]]; then
        err "Media root not found: $MEDIA_ROOT"
        return 1
    fi

    info "Scanning: $MEDIA_ROOT"
    echo ""

    local total_files=0 total_size=0

    while IFS= read -r -d '' dir; do
        local dirname count size_hr
        dirname=$(basename "$dir")
        count=$(find "$dir" -type f 2>/dev/null | wc -l)
        size_hr=$(du -sh "$dir" 2>/dev/null | cut -f1)
        total_files=$((total_files + count))
        printf "  %-30s %6d files   %8s\n" "$dirname/" "$count" "$size_hr"
    done < <(find "$MEDIA_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    total_size=$(du -sh "$MEDIA_ROOT" 2>/dev/null | cut -f1)
    echo "  ────────────────────────────────────────────────────"
    printf "  %-30s %6d files   %8s\n" "TOTAL" "$total_files" "$total_size"

    header "File Type Breakdown"
    find "$MEDIA_ROOT" -type f 2>/dev/null | \
        sed 's/.*\.//' | sort | uniq -ci | sort -rn | head -15 | \
        awk '{printf "  %-12s %d files\n", $2, $1}'
}

cmd_transcode() {
    header "Transcode Cache Status"

    if [[ ! -d "$TRANSCODE_DIR" ]]; then
        warn "Transcode directory not found: $TRANSCODE_DIR"
        info "Jellyfin may use a different path — check your dashboard settings"
        return 0
    fi

    local size_bytes size_hr file_count
    size_bytes=$(du -sb "$TRANSCODE_DIR" 2>/dev/null | cut -f1)
    size_hr=$(du -sh "$TRANSCODE_DIR" 2>/dev/null | cut -f1)
    file_count=$(find "$TRANSCODE_DIR" -type f 2>/dev/null | wc -l)

    printf "  Location:  %s\n" "$TRANSCODE_DIR"
    printf "  Size:      %s (%d files)\n" "$size_hr" "$file_count"

    local size_gb=$(( size_bytes / 1073741824 ))
    if (( size_gb >= TRANSCODE_WARN_GB )); then
        warn "Transcode cache is over ${TRANSCODE_WARN_GB}GB!"
    else
        ok "Cache size is within limits"
    fi
}

cmd_transcode_clear() {
    header "Clear Transcode Cache"

    if [[ ! -d "$TRANSCODE_DIR" ]]; then
        warn "Transcode directory not found: $TRANSCODE_DIR"
        return 0
    fi

    local size_hr
    size_hr=$(du -sh "$TRANSCODE_DIR" 2>/dev/null | cut -f1)
    info "Current cache size: $size_hr"

    read -rp "Clear all transcode cache files? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo find "$TRANSCODE_DIR" -type f -delete 2>/dev/null
        ok "Transcode cache cleared"
    else
        info "Cancelled"
    fi
}

cmd_logs() {
    header "Recent Jellyfin Logs"
    local lines=${1:-30}
    info "Showing last $lines lines (pass a number for more, e.g. '$0 logs 100')"
    echo ""
    journalctl -u "$JELLYFIN_SERVICE" --no-pager -n "$lines"
}

cmd_errors() {
    header "Recent Jellyfin Errors"
    info "Filtering journal for errors/warnings (last 50)..."
    echo ""
    journalctl -u "$JELLYFIN_SERVICE" --no-pager -p err -n 50
}

cmd_restart() {
    header "Restart Jellyfin"
    info "Restarting $JELLYFIN_SERVICE..."
    sudo systemctl restart "$JELLYFIN_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$JELLYFIN_SERVICE"; then
        ok "Jellyfin restarted successfully"
    else
        err "Jellyfin failed to start — check logs with: $0 logs"
    fi
}

cmd_duplicates() {
    header "Scanning for Duplicate Media Files"
    if [[ ! -d "$MEDIA_ROOT" ]]; then
        err "Media root not found: $MEDIA_ROOT"
        return 1
    fi

    info "Finding files with identical names (different paths)..."
    info "This may take a moment for large libraries..."
    echo ""

    find "$MEDIA_ROOT" -type f \
        -not -name "*.nfo" -not -name "*.srt" -not -name "*.sub" \
        -not -name "*.jpg" -not -name "*.png" -not -name "*.xml" \
        -printf '%f\t%p\n' 2>/dev/null | \
        sort | awk -F'\t' '
        prev == $1 { if (!printed) { print prev_line; printed=1 }; print $0 }
        prev != $1 { prev=$1; prev_line=$0; printed=0 }
        ' | column -t -s $'\t'

    local count
    count=$(find "$MEDIA_ROOT" -type f \
        -not -name "*.nfo" -not -name "*.srt" -not -name "*.sub" \
        -not -name "*.jpg" -not -name "*.png" -not -name "*.xml" \
        -printf '%f\n' 2>/dev/null | sort | uniq -d | wc -l)

    echo ""
    if (( count > 0 )); then
        warn "Found $count filename(s) appearing in multiple locations"
    else
        ok "No duplicate filenames detected"
    fi
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
${BOLD}Jellyfin Library Manager${NC}

${BOLD}Usage:${NC} $0 <command>

${BOLD}Commands:${NC}
  status          Show Jellyfin service status and resource usage
  scan            Trigger a library scan via API
  library         Overview of media library (sizes, file counts, types)
  transcode       Show transcode cache status
  transcode-clear Clear the transcode cache
  logs [N]        Show last N journal lines (default: 30)
  errors          Show recent errors from the journal
  restart         Restart the Jellyfin service
  duplicates      Find potential duplicate media files

${BOLD}Configuration:${NC}
  Edit the variables at the top of this script to match your setup.
  Set JELLYFIN_API_KEY for API-based library scans.

EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    status)          cmd_status ;;
    scan)            cmd_scan ;;
    library)         cmd_library ;;
    transcode)       cmd_transcode ;;
    transcode-clear) cmd_transcode_clear ;;
    logs)            cmd_logs "${2:-30}" ;;
    errors)          cmd_errors ;;
    restart)         cmd_restart ;;
    duplicates)      cmd_duplicates ;;
    -h|--help|"")    usage ;;
    *)               err "Unknown command: $1"; usage; exit 1 ;;
esac
