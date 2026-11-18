#!/usr/bin/env bash
#
# tempswap.sh - create a temporary swap file that is removed on Ctrl+C
#
# Usage: sudo ./tempswap.sh [directory]
#   directory defaults to /
#   The swap file gets a random name (tempswap.XXXXXXXX.img), so several
#   instances can run at the same time.

set -u

DIR="${1:-/}"
SWAPFILE=""
ACTIVE=0

# --- must be root ---------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo -- "$0" "$@"
fi

if [[ ! -d "$DIR" ]]; then
    echo "Error: $DIR is not a directory." >&2
    exit 1
fi

# --- cleanup handler ------------------------------------------------------
cleanup() {
    trap - INT TERM EXIT
    echo
    if [[ $ACTIVE -eq 1 ]]; then
        echo "Deactivating $SWAPFILE (this can take a while if it is in use)..."
        if ! swapoff "$SWAPFILE"; then
            echo "Error: swapoff failed (not enough free RAM?). File left at $SWAPFILE." >&2
            exit 1
        fi
    fi
    if [[ -n "$SWAPFILE" && -e "$SWAPFILE" ]]; then
        echo "Deleting $SWAPFILE..."
        rm -f -- "$SWAPFILE"
    fi
    echo "Done."
    exit 0
}
trap cleanup INT TERM EXIT

# --- ask for size ---------------------------------------------------------
while true; do
    read -rp "Swap size in GB: " SIZE_GB
    if [[ "$SIZE_GB" =~ ^[0-9]+$ ]] && (( SIZE_GB > 0 )); then
        break
    fi
    echo "Please enter a positive whole number."
done

# --- check free space -----------------------------------------------------
FREE_KB=$(df --output=avail -k -- "$DIR" | tail -n1 | tr -d ' ')
NEED_KB=$(( SIZE_GB * 1024 * 1024 ))
if (( FREE_KB < NEED_KB + 1024 * 1024 )); then
    echo "Error: not enough free space in $DIR ($(( FREE_KB / 1024 / 1024 )) GB available)." >&2
    exit 1
fi

# --- create the file with a random name -----------------------------------
SWAPFILE="$(mktemp -p "$DIR" tempswap.XXXXXXXX.img)" || { SWAPFILE=""; exit 1; }
SWAPFILE="$(realpath -- "$SWAPFILE")"   # canonical path, matches /proc/swaps
chmod 600 "$SWAPFILE"

FSTYPE="$(stat -f -c %T -- "$DIR")"
echo "Creating ${SIZE_GB} GB swap file at $SWAPFILE (filesystem: $FSTYPE)..."

if [[ "$FSTYPE" == "btrfs" ]]; then
    # btrfs needs a NOCOW file; the attribute must be set while it's still empty
    chattr +C "$SWAPFILE" || exit 1
fi

# fallocate is fast; fall back to dd where it isn't supported
if ! fallocate -l "${SIZE_GB}G" "$SWAPFILE" 2>/dev/null; then
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( SIZE_GB * 1024 )) status=progress || exit 1
fi

mkswap "$SWAPFILE" >/dev/null || exit 1

# --- activate -------------------------------------------------------------
if ! swapon "$SWAPFILE"; then
    # some filesystems reject fallocated files; retry once with a zero-filled file
    echo "swapon failed, retrying with a zero-filled file..."
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( SIZE_GB * 1024 )) status=progress || exit 1
    mkswap "$SWAPFILE" >/dev/null || exit 1
    swapon "$SWAPFILE" || exit 1
fi
ACTIVE=1

echo
echo "Swap file active: $SWAPFILE (${SIZE_GB} GB)"
echo "Press Ctrl+C to deactivate and delete it."
echo

# --- live memory monitor --------------------------------------------------
# KiB -> "12.3 GiB"
fmt() { awk -v k="$1" 'BEGIN { printf "%6.2f GiB", k / 1048576 }'; }

# draws a 30-char bar for used/total
bar() {
    local used=$1 total=$2 width=30 filled pct
    if (( total > 0 )); then
        filled=$(( used * width / total ))
        pct=$(( used * 100 / total ))
    else
        filled=0; pct=0
    fi
    printf '['
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' $(( width - filled )) '' | tr ' ' '-'
    printf '] %3d%%' "$pct"
}

LINES_DRAWN=0
while true; do
    # read /proc/meminfo (values in KiB)
    while read -r key val _; do
        case "$key" in
            MemTotal:)     MEM_TOTAL=$val ;;
            MemAvailable:) MEM_AVAIL=$val ;;
            SwapTotal:)    SWAP_TOTAL=$val ;;
            SwapFree:)     SWAP_FREE=$val ;;
        esac
    done < /proc/meminfo
    MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
    SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE ))

    # usage of this script's swap file (/proc/swaps: Filename Type Size Used Priority)
    read -r FILE_SIZE FILE_USED < <(awk -v f="$SWAPFILE" '$1 == f { print $3, $4 }' /proc/swaps)
    FILE_SIZE=${FILE_SIZE:-0}; FILE_USED=${FILE_USED:-0}

    # move cursor back up to overwrite the previous block
    (( LINES_DRAWN > 0 )) && printf '\033[%dA' "$LINES_DRAWN"

    printf '\033[K%s\n' "$(date '+%H:%M:%S')"
    printf '\033[KRAM        %s / %s  %s\n' "$(fmt "$MEM_USED")"  "$(fmt "$MEM_TOTAL")"  "$(bar "$MEM_USED" "$MEM_TOTAL")"
    printf '\033[KSwap total %s / %s  %s\n' "$(fmt "$SWAP_USED")" "$(fmt "$SWAP_TOTAL")" "$(bar "$SWAP_USED" "$SWAP_TOTAL")"
    printf '\033[KThis file  %s / %s  %s\n' "$(fmt "$FILE_USED")" "$(fmt "$FILE_SIZE")" "$(bar "$FILE_USED" "$FILE_SIZE")"
    LINES_DRAWN=4

    sleep 1 &
    wait $!
done
