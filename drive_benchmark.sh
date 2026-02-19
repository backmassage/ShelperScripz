#!/usr/bin/env bash
# ============================================================
#  Drive Performance Benchmark
#  Tests sequential read & write speeds using dd
#  Usage: sudo bash drive_benchmark.sh
# ============================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
# Edit these mount points / paths to match YOUR system.
# Each entry: "Label|TestPath|TestSizeMB"
#   - Label       : friendly name shown in results
#   - TestPath    : directory on the drive to write the test file
#   - TestSizeMB  : size of the test file in MB (use smaller for SSDs if desired)

DRIVES=(
  "16TB External HDD (USB 3.2)|/mnt/media|1024"
  "476GB Internal NVMe SSD|/home/joker|2048"
  "1TB External SSD (USB 3.2)|/mnt/HarleyBox|2048"
)

# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
#  IMPORTANT: Change the TestPath values above to match your actual mount
#  points before running!  Use  "lsblk"  or  "df -h"  to find them.
# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

BLOCK_SIZE="1M"          # dd block size
TEST_FILE="bench_test.dat"
RESULTS=()
DIVIDER="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Helpers -----------------------------------------------------------------
bold()  { printf "\033[1m%s\033[0m" "$*"; }
green() { printf "\033[1;32m%s\033[0m" "$*"; }
red()   { printf "\033[1;31m%s\033[0m" "$*"; }
cyan()  { printf "\033[1;36m%s\033[0m" "$*"; }

cleanup() {
  for drive in "${DRIVES[@]}"; do
    IFS='|' read -r _label path _size <<< "$drive"
    rm -f "${path}/${TEST_FILE}" 2>/dev/null || true
  done
}
trap cleanup EXIT

parse_speed() {
  # Extract speed from dd stderr output (handles GB/s, MB/s, kB/s)
  local output="$1"
  echo "$output" | grep -oP '[\d.]+ [GgMmKk]?B/s' | tail -1
}

# --- Pre-flight checks -------------------------------------------------------
echo ""
echo "$DIVIDER"
echo "  $(bold 'DRIVE PERFORMANCE BENCHMARK')"
echo "$DIVIDER"
echo ""
echo "  Drives configured:"
for drive in "${DRIVES[@]}"; do
  IFS='|' read -r label path size <<< "$drive"
  echo "    • $label"
  echo "      Path: $path  |  Test size: ${size} MB"
done
echo ""

# Check paths exist
ALL_OK=true
for drive in "${DRIVES[@]}"; do
  IFS='|' read -r label path size <<< "$drive"
  if [[ ! -d "$path" ]]; then
    red "  ✗ Path not found: $path ($label)\n"
    echo "    Update the DRIVES array in this script with your actual mount points."
    ALL_OK=false
  fi
done

if [[ "$ALL_OK" != true ]]; then
  echo ""
  echo "  Tip: Run $(cyan 'lsblk -o NAME,SIZE,MOUNTPOINT') or $(cyan 'df -h') to find mount points."
  echo ""
  exit 1
fi

echo "  Starting benchmarks… (this may take a few minutes)"
echo ""

# --- Run benchmarks -----------------------------------------------------------
for drive in "${DRIVES[@]}"; do
  IFS='|' read -r label path size <<< "$drive"
  filepath="${path}/${TEST_FILE}"
  count=$((size))

  echo "$DIVIDER"
  echo "  $(bold "$label")"
  echo "  Path: $path  |  Test file: ${size} MB"
  echo "$DIVIDER"

  # ---- WRITE TEST ----
  printf "  %-20s" "Write speed:"
  sync
  write_output=$(dd if=/dev/zero of="$filepath" bs=${BLOCK_SIZE} count=${count} conv=fdatasync oflag=direct 2>&1) || true
  write_speed=$(parse_speed "$write_output")
  if [[ -n "$write_speed" ]]; then
    green "$write_speed\n"
  else
    red "Could not parse result\n"
    write_speed="N/A"
  fi

  # ---- READ TEST (drop caches first) ----
  printf "  %-20s" "Read speed:"
  # Attempt to drop caches (needs root); skip silently if not available
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  read_output=$(dd if="$filepath" of=/dev/null bs=${BLOCK_SIZE} count=${count} iflag=direct 2>&1) || true
  read_speed=$(parse_speed "$read_output")
  if [[ -n "$read_speed" ]]; then
    green "$read_speed\n"
  else
    red "Could not parse result\n"
    read_speed="N/A"
  fi

  # ---- LATENCY TEST (4K random read via dd, 1000 ops) ----
  printf "  %-20s" "4K random latency:"
  lat_start=$(date +%s%N)
  for ((i=0; i<1000; i++)); do
    # Read a random 4K block from the test file
    max_blocks=$((size * 256))  # 256 4K-blocks per MB
    offset=$((RANDOM % max_blocks))
    dd if="$filepath" of=/dev/null bs=4096 count=1 skip=$offset iflag=direct 2>/dev/null || true
  done
  lat_end=$(date +%s%N)
  lat_us=$(( (lat_end - lat_start) / 1000000 ))  # total ms for 1000 ops
  avg_lat=$(echo "scale=2; $lat_us / 1000" | bc 2>/dev/null || echo "$((lat_us / 1000))")
  green "${avg_lat} ms avg (1000 x 4K reads)\n"

  # Cleanup test file now
  rm -f "$filepath" 2>/dev/null || true

  RESULTS+=("$label|$write_speed|$read_speed|${avg_lat} ms")
  echo ""
done

# --- Summary ------------------------------------------------------------------
echo "$DIVIDER"
echo "  $(bold 'SUMMARY')"
echo "$DIVIDER"
printf "  %-38s  %-16s  %-16s  %-14s\n" "Drive" "Write" "Read" "4K Latency"
echo "  $(printf '%.0s─' {1..88})"
for result in "${RESULTS[@]}"; do
  IFS='|' read -r label write read lat <<< "$result"
  printf "  %-38s  %-16s  %-16s  %-14s\n" "$label" "$write" "$read" "$lat"
done
echo ""

# --- Expectations reference ---
echo "  $(bold 'Expected Ballpark Speeds:')"
echo "  ┌────────────────────────────────────┬───────────────┬───────────────┐"
echo "  │ Drive Type                         │ Write         │ Read          │"
echo "  ├────────────────────────────────────┼───────────────┼───────────────┤"
echo "  │ HDD (USB 3.2)                      │ 100–200 MB/s  │ 100–200 MB/s  │"
echo "  │ SATA SSD (internal)                │ 400–550 MB/s  │ 450–560 MB/s  │"
echo "  │ NVMe SSD (internal)                │ 1–5 GB/s      │ 2–7 GB/s      │"
echo "  │ External SSD (USB 3.2 Gen 2)       │ 800–1000 MB/s │ 900–1050 MB/s │"
echo "  │ External SSD (USB 3.2 Gen 1)       │ 400–450 MB/s  │ 400–450 MB/s  │"
echo "  └────────────────────────────────────┴───────────────┴───────────────┘"
echo ""
echo "  $(bold 'Notes:')"
echo "  • Run with $(cyan 'sudo') for accurate reads (needed to drop disk cache)."
echo "  • Close other disk-heavy apps during the test."
echo "  • USB enclosure chipset can bottleneck external SSD speeds."
echo "  • Results vary with drive fullness, temperature, and fragmentation."
echo ""
