#!/usr/bin/env bash
# =============================================================================
# das-health.sh — DAS Enclosure Health & Monitoring
# For: USB multi-bay JBOD/RAID enclosure on Arch Linux
# Usage: ./das-health.sh [command]
# Deps: smartmontools, lsblk, udisks2 (most pre-installed on Arch)
# =============================================================================
set -euo pipefail

# ── Configuration (edit these to match your setup) ───────────────────────────
# Mount points to monitor — add all your DAS mount points here
MOUNT_POINTS=(
    "/mnt/media"
    # "/mnt/data"
    # "/mnt/backup"
)

# DAS drives — leave empty to auto-detect USB-attached block devices
# Or specify manually, e.g.: DAS_DRIVES=("/dev/sda" "/dev/sdb" "/dev/sdc")
DAS_DRIVES=()

# Thresholds
TEMP_WARN=45       # Drive temp warning threshold (°C)
TEMP_CRIT=55       # Drive temp critical threshold (°C)
DISK_USAGE_WARN=85 # Warn when mount usage exceeds this %
DISK_USAGE_CRIT=95 # Critical when mount usage exceeds this %

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*"; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Helpers ──────────────────────────────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "SMART queries require root. Re-run with: sudo $0 $*"
        exit 1
    fi
}

# Auto-detect USB-attached block devices (likely DAS drives)
detect_das_drives() {
    if [[ ${#DAS_DRIVES[@]} -gt 0 ]]; then
        return
    fi
    mapfile -t DAS_DRIVES < <(
        lsblk -dno NAME,TRAN 2>/dev/null | awk '$2 == "usb" {print "/dev/"$1}'
    )
    if [[ ${#DAS_DRIVES[@]} -eq 0 ]]; then
        warn "No USB block devices detected. You can set DAS_DRIVES manually in the script."
    fi
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_overview() {
    header "DAS Enclosure Overview"

    detect_das_drives

    if [[ ${#DAS_DRIVES[@]} -eq 0 ]]; then
        err "No DAS drives found"
        return 1
    fi

    printf "  ${BOLD}%-10s %-8s %-20s %-12s %-10s${NC}\n" "DEVICE" "SIZE" "MODEL" "SERIAL" "TRANSPORT"
    for dev in "${DAS_DRIVES[@]}"; do
        if [[ ! -b "$dev" ]]; then
            warn "Device not found: $dev"
            continue
        fi
        local name size model serial tran
        name=$(basename "$dev")
        size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "?")
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs || echo "?")
        serial=$(lsblk -dno SERIAL "$dev" 2>/dev/null | xargs || echo "?")
        tran=$(lsblk -dno TRAN "$dev" 2>/dev/null || echo "?")
        printf "  %-10s %-8s %-20s %-12s %-10s\n" "$name" "$size" "$model" "$serial" "$tran"
    done

    header "Partition Layout"
    for dev in "${DAS_DRIVES[@]}"; do
        [[ -b "$dev" ]] || continue
        echo -e "  ${BOLD}$dev${NC}"
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL "$dev" 2>/dev/null | tail -n +2 | sed 's/^/    /'
        echo ""
    done
}

cmd_mounts() {
    header "Mount Point Status"

    if [[ ${#MOUNT_POINTS[@]} -eq 0 ]]; then
        warn "No mount points configured. Edit MOUNT_POINTS in the script."
        return 0
    fi

    local all_ok=true

    for mp in "${MOUNT_POINTS[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            local usage total used avail
            read -r total used avail usage <<< "$(df -h "$mp" | awk 'NR==2 {print $2, $3, $4, $5}')"
            usage=${usage%\%}  # strip %

            local color="$GREEN"
            local status_icon="✓"
            if (( usage >= DISK_USAGE_CRIT )); then
                color="$RED"; status_icon="✗"; all_ok=false
            elif (( usage >= DISK_USAGE_WARN )); then
                color="$YELLOW"; status_icon="!"; all_ok=false
            fi

            printf "  ${color}[%s]${NC} %-25s %s / %s used (%s%% — %s free)\n" \
                "$status_icon" "$mp" "$used" "$total" "$usage" "$avail"
        else
            err "NOT MOUNTED: $mp"
            all_ok=false

            # Try to identify what should be there
            local fstab_entry
            fstab_entry=$(grep -E "\\s${mp}\\s" /etc/fstab 2>/dev/null || true)
            if [[ -n "$fstab_entry" ]]; then
                info "  fstab entry found: $(echo "$fstab_entry" | awk '{print $1, $3}')"
                info "  Try: sudo mount $mp"
            fi
        fi
    done

    if $all_ok; then
        echo ""
        ok "All mount points healthy"
    fi
}

cmd_smart() {
    check_root
    detect_das_drives
    header "SMART Health Summary"

    if [[ ${#DAS_DRIVES[@]} -eq 0 ]]; then
        err "No DAS drives found"
        return 1
    fi

    for dev in "${DAS_DRIVES[@]}"; do
        [[ -b "$dev" ]] || continue
        local name model
        name=$(basename "$dev")
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs || echo "unknown")

        echo -e "\n  ${BOLD}$name${NC} ($model)"

        # Check if SMART is supported
        if ! smartctl -i "$dev" &>/dev/null; then
            warn "  SMART not available (USB bridge may not pass through SMART)"
            info "  Try: smartctl -d sat $dev  or  smartctl -d usbcypress $dev"
            continue
        fi

        # Overall health
        local health
        health=$(smartctl -H "$dev" 2>/dev/null | grep -i "result\|status" | head -1 || echo "")
        if echo "$health" | grep -qi "passed\|ok"; then
            ok "  Health: PASSED"
        elif [[ -n "$health" ]]; then
            err "  Health: $health"
        else
            warn "  Health: Could not determine (USB passthrough issue?)"
            info "  Trying SAT passthrough..."
            health=$(smartctl -d sat -H "$dev" 2>/dev/null | grep -i "result\|status" | head -1 || echo "")
            if echo "$health" | grep -qi "passed\|ok"; then
                ok "  Health (SAT): PASSED"
            else
                warn "  Health (SAT): ${health:-unknown}"
            fi
        fi

        # Temperature
        local temp
        temp=$(smartctl -A "$dev" 2>/dev/null | grep -i "temperature" | head -1 | awk '{print $(NF-0)}' || echo "")
        if [[ -z "$temp" ]]; then
            temp=$(smartctl -d sat -A "$dev" 2>/dev/null | grep -i "temperature" | head -1 | awk '{print $(NF-0)}' || echo "")
        fi

        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]]; then
            local color="$GREEN"
            if (( temp >= TEMP_CRIT )); then
                color="$RED"
            elif (( temp >= TEMP_WARN )); then
                color="$YELLOW"
            fi
            printf "  Temp:   ${color}%d°C${NC}\n" "$temp"
        else
            info "  Temp:   not available"
        fi

        # Key SMART attributes
        local power_on reallocated pending
        power_on=$(smartctl -A "$dev" 2>/dev/null | grep -i "power_on_hours\|Power On Hours" | awk '{print $NF}' || echo "?")
        reallocated=$(smartctl -A "$dev" 2>/dev/null | grep -i "reallocated_sector\|Reallocated Sector" | awk '{print $NF}' || echo "?")
        pending=$(smartctl -A "$dev" 2>/dev/null | grep -i "current_pending\|Current Pending" | awk '{print $NF}' || echo "?")

        printf "  Power-on hours:     %s\n" "${power_on:-?}"
        if [[ "$reallocated" =~ ^[0-9]+$ && "$reallocated" -gt 0 ]]; then
            warn "  Reallocated sectors: $reallocated"
        else
            printf "  Reallocated sectors: %s\n" "${reallocated:-0}"
        fi
        if [[ "$pending" =~ ^[0-9]+$ && "$pending" -gt 0 ]]; then
            warn "  Pending sectors:     $pending"
        else
            printf "  Pending sectors:     %s\n" "${pending:-0}"
        fi
    done
}

cmd_smart_full() {
    check_root
    detect_das_drives
    header "Full SMART Report"

    if [[ ${#DAS_DRIVES[@]} -eq 0 ]]; then
        err "No DAS drives found"
        return 1
    fi

    local dev="${2:-${DAS_DRIVES[0]}}"
    info "Full SMART data for $dev"
    info "(For SAT passthrough, run: sudo smartctl -d sat -a $dev)"
    echo ""
    smartctl -a "$dev" 2>/dev/null || smartctl -d sat -a "$dev" 2>/dev/null || \
        err "Could not read SMART data from $dev"
}

cmd_temps() {
    check_root
    detect_das_drives
    header "Drive Temperatures"

    if [[ ${#DAS_DRIVES[@]} -eq 0 ]]; then
        err "No DAS drives found"
        return 1
    fi

    printf "  ${BOLD}%-10s %-20s %-10s${NC}\n" "DEVICE" "MODEL" "TEMP"
    for dev in "${DAS_DRIVES[@]}"; do
        [[ -b "$dev" ]] || continue
        local name model temp
        name=$(basename "$dev")
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs || echo "?")

        temp=$(smartctl -A "$dev" 2>/dev/null | grep -i "temperature" | head -1 | awk '{print $NF}' || echo "")
        if [[ -z "$temp" ]]; then
            temp=$(smartctl -d sat -A "$dev" 2>/dev/null | grep -i "temperature" | head -1 | awk '{print $NF}' || echo "")
        fi

        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]]; then
            local color="$GREEN"
            if (( temp >= TEMP_CRIT )); then color="$RED"
            elif (( temp >= TEMP_WARN )); then color="$YELLOW"
            fi
            printf "  %-10s %-20s ${color}%d°C${NC}\n" "$name" "$model" "$temp"
        else
            printf "  %-10s %-20s ${DIM}n/a${NC}\n" "$name" "$model"
        fi
    done
}

cmd_io() {
    detect_das_drives
    header "I/O Statistics"

    if [[ ${#DAS_DRIVES[@]} -eq 0 ]]; then
        err "No DAS drives found"
        return 1
    fi

    printf "  ${BOLD}%-8s %12s %12s %12s %12s${NC}\n" "DEVICE" "READ" "WRITTEN" "IO_SEC" "AWAIT"
    for dev in "${DAS_DRIVES[@]}"; do
        [[ -b "$dev" ]] || continue
        local name
        name=$(basename "$dev")

        if [[ -f "/sys/block/$name/stat" ]]; then
            local read_sectors write_sectors
            read -r _ _ read_sectors _ _ _ write_sectors _ < "/sys/block/$name/stat"
            local read_gb write_gb
            read_gb=$(awk "BEGIN {printf \"%.1f GB\", $read_sectors * 512 / 1073741824}")
            write_gb=$(awk "BEGIN {printf \"%.1f GB\", $write_sectors * 512 / 1073741824}")
            printf "  %-8s %12s %12s\n" "$name" "$read_gb" "$write_gb"
        fi
    done

    echo ""
    info "Live I/O (5 second snapshot):"
    if command -v iostat &>/dev/null; then
        local dev_names=()
        for dev in "${DAS_DRIVES[@]}"; do
            dev_names+=("$(basename "$dev")")
        done
        iostat -dxh "${dev_names[@]}" 1 2 2>/dev/null | tail -n +$((${#dev_names[@]} + 3))
    else
        warn "iostat not found — install sysstat: sudo pacman -S sysstat"
    fi
}

cmd_health() {
    # Combined quick health check
    cmd_mounts
    cmd_smart
    cmd_temps
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
${BOLD}DAS Health & Monitoring${NC}

${BOLD}Usage:${NC} $0 <command>

${BOLD}Commands:${NC}
  overview       Show DAS drives, models, partitions
  mounts         Check mount points and disk usage
  smart          SMART health summary for all DAS drives (requires sudo)
  smart-full     Full SMART report for a drive (requires sudo)
  temps          Drive temperatures (requires sudo)
  io             I/O statistics and live snapshot
  health         Combined quick check (mounts + smart + temps)

${BOLD}Notes:${NC}
  • USB enclosures may not pass through SMART data. The script tries
    SAT passthrough (-d sat) as a fallback automatically.
  • Edit DAS_DRIVES and MOUNT_POINTS at the top to match your setup.
  • Most commands need sudo for SMART access.

EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    overview)   cmd_overview ;;
    mounts)     cmd_mounts ;;
    smart)      cmd_smart ;;
    smart-full) cmd_smart_full "$@" ;;
    temps)      cmd_temps ;;
    io)         cmd_io ;;
    health)     cmd_health ;;
    -h|--help|"") usage ;;
    *)          err "Unknown command: $1"; usage; exit 1 ;;
esac
