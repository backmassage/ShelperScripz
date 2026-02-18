#!/usr/bin/env bash
# =============================================================================
# tree-print.sh — Pretty Folder & File Structure Printer
# Usage: ./tree-print.sh [OPTIONS] [path]
# =============================================================================
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
MAX_DEPTH=3
SHOW_HIDDEN=false
SHOW_SIZE=false
SHOW_PERMS=false
SHOW_DATE=false
DIRS_ONLY=false
FILES_ONLY=false
OUTPUT_FILE=""
NO_COLOR=false
FILTER_EXT=""
EXCLUDE_PATTERN=""
SORT_BY="name"  # name, size, date
COUNT_ONLY=false

# ── Colors ───────────────────────────────────────────────────────────────────
C_DIR='\033[1;34m'     # Bold blue
C_EXEC='\033[1;32m'    # Bold green
C_LINK='\033[1;36m'    # Bold cyan
C_MEDIA='\033[0;35m'   # Purple
C_ARCHIVE='\033[0;31m' # Red
C_DIM='\033[2m'        # Dim
C_BOLD='\033[1m'       # Bold
NC='\033[0m'

# ── File type colorization ───────────────────────────────────────────────────
colorize_name() {
    local name="$1" path="$2"

    if $NO_COLOR; then
        echo "$name"
        return
    fi

    if [[ -d "$path" ]]; then
        echo -e "${C_DIR}${name}/${NC}"
    elif [[ -L "$path" ]]; then
        local target
        target=$(readlink "$path" 2>/dev/null || echo "?")
        echo -e "${C_LINK}${name}${NC} ${C_DIM}→ ${target}${NC}"
    elif [[ -x "$path" ]]; then
        echo -e "${C_EXEC}${name}${NC}"
    else
        case "${name,,}" in
            *.mp4|*.mkv|*.avi|*.mov|*.wmv|*.flv|*.webm|*.m4v| \
            *.mp3|*.flac|*.ogg|*.wav|*.aac|*.m4a| \
            *.jpg|*.jpeg|*.png|*.gif|*.bmp|*.svg|*.webp|*.tiff)
                echo -e "${C_MEDIA}${name}${NC}" ;;
            *.tar|*.gz|*.bz2|*.xz|*.zip|*.rar|*.7z|*.zst)
                echo -e "${C_ARCHIVE}${name}${NC}" ;;
            *)
                echo "$name" ;;
        esac
    fi
}

# ── Metadata helpers ─────────────────────────────────────────────────────────
get_size() {
    local path="$1"
    if [[ -f "$path" ]]; then
        local bytes
        bytes=$(stat -c %s "$path" 2>/dev/null || echo 0)
        if (( bytes >= 1073741824 )); then
            awk "BEGIN {printf \"%.1fG\", $bytes/1073741824}"
        elif (( bytes >= 1048576 )); then
            awk "BEGIN {printf \"%.1fM\", $bytes/1048576}"
        elif (( bytes >= 1024 )); then
            awk "BEGIN {printf \"%.1fK\", $bytes/1024}"
        else
            echo "${bytes}B"
        fi
    elif [[ -d "$path" ]]; then
        echo "<dir>"
    fi
}

get_perms() {
    stat -c "%A" "$1" 2>/dev/null || echo "?"
}

get_date() {
    stat -c "%y" "$1" 2>/dev/null | cut -d'.' -f1 || echo "?"
}

# ── Core tree walker ─────────────────────────────────────────────────────────
walk_tree() {
    local dir="$1" prefix="$2" depth="$3"

    if (( depth > MAX_DEPTH )); then
        return
    fi

    # Build the file list
    local entries=()
    local ls_opts="-1"
    $SHOW_HIDDEN || ls_opts+="I '.*'"

    while IFS= read -r -d '' entry; do
        local name
        name=$(basename "$entry")

        # Skip hidden files unless requested
        if ! $SHOW_HIDDEN && [[ "$name" == .* ]]; then
            continue
        fi

        # Apply extension filter
        if [[ -n "$FILTER_EXT" && -f "$entry" ]]; then
            local ext="${name##*.}"
            if [[ ",$FILTER_EXT," != *",$ext,"* ]]; then
                continue
            fi
        fi

        # Apply exclude pattern
        if [[ -n "$EXCLUDE_PATTERN" ]]; then
            if [[ "$name" =~ $EXCLUDE_PATTERN ]]; then
                continue
            fi
        fi

        # Dirs only / files only
        if $DIRS_ONLY && [[ ! -d "$entry" ]]; then continue; fi
        if $FILES_ONLY && [[ -d "$entry" ]]; then continue; fi

        entries+=("$entry")
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)

    # Sort entries (directories first, then by chosen criterion)
    local sorted_dirs=() sorted_files=()
    for entry in "${entries[@]}"; do
        if [[ -d "$entry" ]]; then
            sorted_dirs+=("$entry")
        else
            sorted_files+=("$entry")
        fi
    done

    local all_sorted=("${sorted_dirs[@]}" "${sorted_files[@]}")
    local count=${#all_sorted[@]}
    local i=0

    for entry in "${all_sorted[@]}"; do
        i=$((i + 1))
        local name connector branch
        name=$(basename "$entry")

        if (( i == count )); then
            connector="└── "
            branch="    "
        else
            connector="├── "
            branch="│   "
        fi

        # Build the line
        local line="${prefix}${connector}"
        local display_name
        display_name=$(colorize_name "$name" "$entry")

        # Append metadata
        local meta=""
        if $SHOW_SIZE; then
            meta+="  $(get_size "$entry")"
        fi
        if $SHOW_PERMS; then
            meta+="  $(get_perms "$entry")"
        fi
        if $SHOW_DATE; then
            meta+="  $(get_date "$entry")"
        fi

        if [[ -n "$meta" ]]; then
            echo -e "${line}${display_name}${C_DIM}${meta}${NC}"
        else
            echo -e "${line}${display_name}"
        fi

        # Recurse into directories
        if [[ -d "$entry" && ! -L "$entry" ]]; then
            walk_tree "$entry" "${prefix}${branch}" $((depth + 1))
        fi
    done
}

# ── Summary stats ────────────────────────────────────────────────────────────
print_summary() {
    local target="$1"
    local find_opts=()
    $SHOW_HIDDEN || find_opts+=(-not -name ".*" -not -path "*/.*")

    local dir_count file_count total_size
    dir_count=$(find "$target" -type d "${find_opts[@]}" 2>/dev/null | wc -l)
    dir_count=$((dir_count - 1)) # exclude root
    file_count=$(find "$target" -type f "${find_opts[@]}" 2>/dev/null | wc -l)
    total_size=$(du -sh "$target" 2>/dev/null | cut -f1)

    echo ""
    echo -e "${C_DIM}${dir_count} directories, ${file_count} files, ${total_size} total${NC}"
}

cmd_count() {
    local target="$1"
    local find_opts=()
    $SHOW_HIDDEN || find_opts+=(-not -name ".*" -not -path "*/.*")

    echo -e "${C_BOLD}File type breakdown: ${target}${NC}\n"

    find "$target" -type f "${find_opts[@]}" 2>/dev/null | \
        sed 's/.*\.//' | sort | uniq -ci | sort -rn | \
        awk '{printf "  %-12s %d\n", $2, $1}'

    echo ""
    local dir_count file_count total_size
    dir_count=$(find "$target" -type d "${find_opts[@]}" 2>/dev/null | wc -l)
    file_count=$(find "$target" -type f "${find_opts[@]}" 2>/dev/null | wc -l)
    total_size=$(du -sh "$target" 2>/dev/null | cut -f1)
    echo -e "  ${C_BOLD}Total:${NC} $dir_count dirs, $file_count files, $total_size"
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
${C_BOLD}tree-print — Pretty Folder & File Structure Printer${NC}

${C_BOLD}Usage:${NC} $0 [OPTIONS] [path]

${C_BOLD}Options:${NC}
  -d, --depth N        Max depth to recurse (default: 3)
  -a, --all            Show hidden files/directories
  -s, --size           Show file sizes
  -p, --perms          Show permissions
  -t, --time           Show modification times
  -D, --dirs-only      Show only directories
  -F, --files-only     Show only files (skip directory entries)
  -e, --ext EXT        Filter by extension(s), comma-separated (e.g. mp4,mkv)
  -x, --exclude PAT    Exclude entries matching regex pattern
  -o, --output FILE    Save output to file (strips color codes)
  -c, --count          Show file type breakdown instead of tree
      --no-color       Disable colors
  -h, --help           Show this help

${C_BOLD}Examples:${NC}
  $0 /mnt/media                     Basic tree of media library
  $0 -d 2 -s /mnt/media             Shallow tree with file sizes
  $0 -e mp4,mkv /mnt/media/Movies   Only show video files
  $0 -D /mnt/media                  Directories only
  $0 --count /mnt/media             File type breakdown
  $0 -a -s -p -t ~/projects         Full details including hidden files
  $0 -o tree.txt /mnt/media         Save to file

EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────

TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--depth)     MAX_DEPTH="$2"; shift 2 ;;
        -a|--all)       SHOW_HIDDEN=true; shift ;;
        -s|--size)      SHOW_SIZE=true; shift ;;
        -p|--perms)     SHOW_PERMS=true; shift ;;
        -t|--time)      SHOW_DATE=true; shift ;;
        -D|--dirs-only) DIRS_ONLY=true; shift ;;
        -F|--files-only)FILES_ONLY=true; shift ;;
        -e|--ext)       FILTER_EXT="$2"; shift 2 ;;
        -x|--exclude)   EXCLUDE_PATTERN="$2"; shift 2 ;;
        -o|--output)    OUTPUT_FILE="$2"; NO_COLOR=true; shift 2 ;;
        -c|--count)     COUNT_ONLY=true; shift ;;
        --no-color)     NO_COLOR=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "Unknown option: $1"; usage; exit 1 ;;
        *)              TARGET="$1"; shift ;;
    esac
done

TARGET="${TARGET:-.}"
TARGET=$(realpath "$TARGET" 2>/dev/null || echo "$TARGET")

if [[ ! -d "$TARGET" ]]; then
    echo -e "${C_BOLD}Error:${NC} Not a directory: $TARGET"
    exit 1
fi

# ── Execute ──────────────────────────────────────────────────────────────────

run_output() {
    if $COUNT_ONLY; then
        cmd_count "$TARGET"
    else
        echo -e "${C_BOLD}${TARGET}${NC}"
        walk_tree "$TARGET" "" 1
        print_summary "$TARGET"
    fi
}

if [[ -n "$OUTPUT_FILE" ]]; then
    run_output | sed 's/\x1b\[[0-9;]*m//g' > "$OUTPUT_FILE"
    echo "Saved to: $OUTPUT_FILE"
else
    run_output
fi
