#!/bin/bash

# ==============================================================================
# Repack Master - Arch Linux Edition (v7 - Final)
# Repacks archives to highly compressed, resilient formats.
# Dependencies: 7z, (optional: rar), awk, numfmt (coreutils)
#
# Usage: ./repack.sh [-t] [-d] [-z | -r] [-s] [-v] file1 [file2 ...]
#
# Flags:
#   -t  (Turbo/Tmp): Use /tmp (RAM) for extraction and compression.
#       FAST but dangerous for files larger than your free RAM.
#   -d  (Delete): Delete/Replace the original archive after success.
#   -z  (Zip Mode): Force output to .zip (LZMA algo).
#   -r  (RAR5 Mode): Force output to .rar (RAR5 algo).
#   -s  (Solid Mode): Enable SOLID compression (Smaller size, less resilient).
#   -v  (Verbose): Show full output from compression tools.
#
# Defaults:
#   Format: .7z (LZMA2 / Non-Solid)
#   Work Dir: The same directory as the original file (Disk).
# ==============================================================================

set -u

# --- Configuration ---
USE_TMP=0
DELETE_ORIG=0
VERBOSE=0
SOLID_MODE=0
MODE="7z"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 1. Global Trap (Ctrl+C Handler) ---
cleanup_and_exit() {
    echo -e "\n${RED}!!! Script Aborted by User !!!${NC}"
    # Remove the current work_dir if variable is set and dir exists
    if [ -n "${work_dir:-}" ] && [ -d "$work_dir" ]; then
        echo -e "${RED}Cleaning up temporary files...${NC}"
        rm -rf "$work_dir"
    fi
    exit 130
}
trap cleanup_and_exit SIGINT

# --- 2. Helper Functions ---
run_cmd() {
    if [ "$VERBOSE" -eq 1 ]; then "$@"; else "$@" > /dev/null 2>&1; fi
}

format_size() {
    # Uses numfmt (standard in Arch coreutils)
    numfmt --to=iec-i --suffix=B "$1"
}

# --- 3. Argument Parsing ---
while getopts "tdzrvs" opt; do
  case $opt in
    t) USE_TMP=1 ;;
    d) DELETE_ORIG=1 ;;
    z) MODE="zip" ;;
    r) MODE="rar" ;;
    s) SOLID_MODE=1 ;;
    v) VERBOSE=1 ;;
    \?) echo "Invalid option: -$OPTARG"; exit 1 ;;
  esac
done
shift $((OPTIND -1))

if [ $# -eq 0 ]; then
    echo "Usage: $0 [-t] [-d] [-z | -r] [-s] [-v] archive_file(s)..."
    exit 1
fi

if [ "$MODE" == "rar" ] && ! command -v rar &> /dev/null; then
    echo -e "${RED}Error: 'rar' not found. (sudo pacman -S rar)${NC}"
    exit 1
fi

# --- 4. Main Loop ---
for full_path in "$@"; do
    start_time=$(date +%s)

    # Resolve Path
    if [ ! -f "$full_path" ]; then
        # Check if it's a valid file before running realpath to avoid errors
        if [ -f "$(realpath "$full_path" 2>/dev/null)" ]; then
             full_path=$(realpath "$full_path")
        else
             echo -e "${RED}Skipping: $full_path (Not a file)${NC}"
             continue
        fi
    else
        full_path=$(realpath "$full_path")
    fi

    # Capture Stats
    orig_size_bytes=$(stat -c%s "$full_path")
    filename=$(basename "$full_path")
    dirname=$(dirname "$full_path")
    basename="${filename%.*}"

    # Settings Logic
    case $MODE in
        zip)
            ext="zip"
            cmd_tool="7z"
            cmd_args=(a -tzip -mm=LZMA -mx=9 -md=64m -mfb=64)
            type_label="ZIP (LZMA)"
            ;;
        rar)
            ext="rar"
            cmd_tool="rar"
            if [ "$SOLID_MODE" -eq 1 ]; then
                 cmd_args=(a -ma5 -m5 -md64m -s)
                 type_label="RAR5 (Solid)"
            else
                 cmd_args=(a -ma5 -m5 -md64m)
                 type_label="RAR5 (Non-Solid)"
            fi
            ;;
        *)
            ext="7z"
            cmd_tool="7z"
            if [ "$SOLID_MODE" -eq 1 ]; then
                 cmd_args=(a -t7z -m0=lzma2 -mx=9 -md=64m -mfb=64 -ms=on)
                 type_label="7z (LZMA2 / Solid)"
            else
                 cmd_args=(a -t7z -m0=lzma2 -mx=9 -md=64m -mfb=64 -ms=off)
                 type_label="7z (LZMA2 / Non-Solid)"
            fi
            ;;
    esac

    # Determine Output Name
    output_file="${dirname}/${basename}.${ext}"
    if [ "$full_path" == "$output_file" ] && [ "$DELETE_ORIG" -eq 0 ]; then
        output_file="${dirname}/${basename}_repacked.${ext}"
    fi

    echo -e "${BLUE}---------------------------------------------------${NC}"
    echo -e "${BLUE}Processing: $filename${NC}"
    echo -e "${BLUE}Target:     $type_label${NC}"

    # --- Step A: Workspace ---
    # Logic: Only use RAM if -t is requested AND there is enough space.
    work_dir=""
    extract_source=""

    # Check RAM requirements if -t is used
    use_ram_safe=0
    if [ "$USE_TMP" -eq 1 ]; then
        tmp_free=$(df -k /tmp | awk 'NR==2 {print $4}')
        # Req: 3x source size (KB)
        req_space=$((orig_size_bytes / 1024 * 3))
        if [ "$req_space" -lt "$tmp_free" ]; then
            use_ram_safe=1
        else
            echo -e "${YELLOW}Warning: Low RAM. Falling back to Disk Mode.${NC}"
        fi
    fi

    if [ "$use_ram_safe" -eq 1 ]; then
        # Create in RAM
        work_dir=$(mktemp -d)
        echo "  -> 🚀 Copying to RAM..."
        cp "$full_path" "$work_dir/input_archive"
        extract_source="$work_dir/input_archive"
    else
        # Create on Disk (same folder as file)
        work_dir=$(mktemp -d -p "$dirname")
        extract_source="$full_path"
    fi

    # --- Step B: Extraction ---
    echo "  -> 📂 Extracting..."
    mkdir "$work_dir/content"
    if ! run_cmd 7z x "$extract_source" -o"$work_dir/content"; then
        echo -e "${RED}  -> Extraction Failed! (Corrupt archive?)${NC}"
        rm -rf "$work_dir"
        continue
    fi

    # --- Step C: Compression ---
    echo "  -> 📦 Compressing..."
    pushd "$work_dir/content" > /dev/null

    if run_cmd "$cmd_tool" "${cmd_args[@]}" "../temp_output.${ext}" .; then
        popd > /dev/null

        # --- Step D: Finalize ---
        echo "  -> 💾 Saving..."
        mv -f "$work_dir/temp_output.${ext}" "$output_file"

        if [ -f "$output_file" ]; then
            end_time=$(date +%s)
            duration=$((end_time - start_time))

            # Stats Logic (Using AWK to replace BC)
            new_size_bytes=$(stat -c%s "$output_file")
            orig_human=$(format_size "$orig_size_bytes")
            new_human=$(format_size "$new_size_bytes")

            # Calculate Ratio
            # Formula: (New - Old) / Old * 100
            if [ "$orig_size_bytes" -gt 0 ]; then
                ratio=$(awk -v new="$new_size_bytes" -v old="$orig_size_bytes" 'BEGIN { printf "%.2f", ((new - old) / old) * 100 }')
            else
                ratio="0.00"
            fi

            # Color Logic (Green if negative/smaller, Red if positive/bigger)
            if [[ "$ratio" == -* ]]; then
                 ratio_color=$GREEN
            else
                 ratio_color=$RED
                 ratio="+$ratio" # Add plus sign for clarity
            fi

            echo -e "${GREEN}  -> Done!${NC}"
            echo -e "     ${CYAN}Time:   ${duration}s${NC}"
            echo -e "     ${CYAN}Size:   $orig_human -> $new_human${NC}"
            echo -e "     ${CYAN}Change: ${ratio_color}${ratio}%${NC}"

            # Delete Logic
            if [ "$DELETE_ORIG" -eq 1 ]; then
                 if [ "$full_path" != "$output_file" ]; then
                     rm "$full_path"
                     echo -e "${GREEN}  -> Original deleted.${NC}"
                 fi
            fi
        else
            echo -e "${RED}  -> Error: Output file verification failed.${NC}"
        fi
    else
        popd > /dev/null
        echo -e "${RED}  -> Compression Failed.${NC}"
    fi

    # Cleanup
    rm -rf "$work_dir"
done

echo -e "${BLUE}All tasks complete.${NC}"
