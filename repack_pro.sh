#!/bin/bash

# ==============================================================================
# Repack Master - Arch Linux Edition (v5 - Final Fix)
# Repacks archives to highly compressed, resilient formats.
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
MODE="7z" # Default mode

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

# --- 1. Helper Function: Run Command Verbose or Silent ---
run_cmd() {
    if [ "$VERBOSE" -eq 1 ]; then
        "$@"
    else
        "$@" > /dev/null 2>&1
    fi
}

# --- 2. Argument Parsing ---
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

# Check for 'rar' binary if RAR mode is selected
if [ "$MODE" == "rar" ] && ! command -v rar &> /dev/null; then
    echo -e "${RED}Error: 'rar' command not found. Install it with: sudo pacman -S rar${NC}"
    exit 1
fi

# --- 3. Main Loop ---
for full_path in "$@"; do
    # Normalize path
    full_path=$(realpath "$full_path")
    
    if [ ! -f "$full_path" ]; then
        echo -e "${RED}Skipping: $full_path (Not a file)${NC}"
        continue
    fi

    filename=$(basename "$full_path")
    dirname=$(dirname "$full_path")
    basename="${filename%.*}"
    
    # Determine Output Format & Command
    case $MODE in
        zip)
            ext="zip"
            cmd_tool="7z"
            cmd_args=(a -tzip -mm=LZMA -mx=9 -md=64m -mfb=64)
            type_label="ZIP (LZMA)"
            if [ "$SOLID_MODE" -eq 1 ]; then
                echo -e "${YELLOW}Note: Zip format does not support Solid compression. Ignoring -s.${NC}"
            fi
            ;;
        rar)
            ext="rar"
            cmd_tool="rar"
            if [ "$SOLID_MODE" -eq 1 ]; then
                cmd_args=(a -ma5 -m5 -md64m -s)
                type_label="RAR5 (Best / Solid)"
            else
                cmd_args=(a -ma5 -m5 -md64m)
                type_label="RAR5 (Best / Non-Solid)"
            fi
            ;;
        *) # Default to 7z
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

    # Calculate initial output name
    output_file="${dirname}/${basename}.${ext}"
    
    # --- SMART OVERWRITE LOGIC ---
    if [ "$full_path" == "$output_file" ]; then
        if [ "$DELETE_ORIG" -eq 1 ]; then
            echo -e "${YELLOW}Warning: Replacing original file (Delete flag active).${NC}"
        else
            output_file="${dirname}/${basename}_repacked.${ext}"
            echo -e "${GREEN}Safety: Output renamed to ${basename}_repacked.${ext}${NC}"
        fi
    fi

    echo -e "${BLUE}---------------------------------------------------${NC}"
    echo -e "${BLUE}Processing: $filename${NC}"
    echo -e "${BLUE}Target:     $type_label${NC}"

    # --- Step A: Workspace Creation (FIXED) ---
    if [ "$USE_TMP" -eq 1 ]; then
        # Check RAM safety
        file_size=$(du -k "$full_path" | cut -f1)
        tmp_free=$(df -k /tmp | awk 'NR==2 {print $4}')
        req_space=$((file_size * 3)) # Rough estimate: Input + Extracted + Output
        
        if [ "$req_space" -gt "$tmp_free" ]; then
             echo -e "${YELLOW}Warning: Not enough RAM in /tmp. Falling back to DISK mode.${NC}"
             # Fallback to disk: Create temp dir in the same folder as file
             work_dir=$(mktemp -d -p "$dirname")
             extract_source="$full_path"
        else
             # RAM Mode
             work_dir=$(mktemp -d) # Defaults to /tmp
             echo "  -> 🚀 Copying to RAM..."
             cp "$full_path" "$work_dir/input_archive"
             extract_source="$work_dir/input_archive"
        fi
    else
        # Disk Mode (Default): Create temp dir next to the file
        work_dir=$(mktemp -d -p "$dirname")
        extract_source="$full_path"
    fi
    
    # Ensure cleanup on exit
    trap "rm -rf '$work_dir'" EXIT

    # --- Step B: Extraction ---
    echo "  -> 📂 Extracting..."
    mkdir "$work_dir/content"
    
    if ! run_cmd 7z x "$extract_source" -o"$work_dir/content"; then
        echo -e "${RED}  -> Extraction Failed! Archive might be corrupt.${NC}"
        rm -rf "$work_dir"
        continue
    fi

    # --- Step C: Compression ---
    echo "  -> 📦 Compressing..."
    pushd "$work_dir/content" > /dev/null
    
    if run_cmd "$cmd_tool" "${cmd_args[@]}" "../temp_output.${ext}" .; then
        popd > /dev/null
        
        # --- Step D: Finalize ---
        echo "  -> 💾 Moving result..."
        
        mv -f "$work_dir/temp_output.${ext}" "$output_file"
        
        if [ -f "$output_file" ]; then
            echo -e "${GREEN}  -> Done: $(basename "$output_file")${NC}"
            
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
        echo -e "${RED}  -> Compression step failed.${NC}"
    fi

    # Cleanup current loop iteration
    rm -rf "$work_dir"
    trap - EXIT
done

echo -e "${BLUE}All tasks complete.${NC}"
