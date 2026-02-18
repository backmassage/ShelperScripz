#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <input_file> [output_file]"
    echo
    echo "Regenerate clean timestamps with a stream-copy remux:"
    echo "  ffmpeg -fflags +genpts -i input.mkv -map 0 -c copy output_fixed.mkv"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Error: ffmpeg not found in PATH" >&2
    exit 1
fi

input_file="$1"
output_file="${2:-}"

if [[ ! -f "$input_file" ]]; then
    echo "Error: input file not found: $input_file" >&2
    exit 1
fi

if [[ -z "$output_file" ]]; then
    input_dir="$(dirname "$input_file")"
    input_base="$(basename "$input_file")"
    input_name="${input_base%.*}"
    input_ext="${input_base##*.}"
    output_file="${input_dir}/${input_name}_fixed.${input_ext}"
fi

echo "Input : $input_file"
echo "Output: $output_file"
echo "Running clean timestamp remux..."

ffmpeg -hide_banner -nostdin -y \
    -fflags +genpts \
    -i "$input_file" \
    -map 0 \
    -c copy \
    "$output_file"

echo "Done."
echo "Test playback again. This usually resolves DTS discontinuities, missing PTS, and out-of-order timestamps."
