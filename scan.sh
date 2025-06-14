#!/bin/bash

# List available scanners and prompt user to choose
choose_scanner() {
    echo "Available scanners:"
    scanimage -L
    echo
    read -p "Enter the device name (e.g., airscan:w1:Samsung M2070 Series ...): " SCANNER
}

# Generate a timestamped filename
timestamp() {
    date '+%F_%H:%M:%S'
}

# Scan a single page
scan_single() {
    FILENAME="$(timestamp).pdf"
    echo "Scanning single page..."
    scanimage -d "$SCANNER" --format tiff | magick tiff:- "$FILENAME"
    echo "Saved as $FILENAME"
}

# Scan multiple pages and merge
scan_multi() {
    TMP_DIR=$(mktemp -d)
    PAGE_NUM=1
    echo "Starting multi-page scan..."

    while true; do
        echo "Scanning page $PAGE_NUM..."
        TMP_FILE="$TMP_DIR/page_$(printf '%03d' "$PAGE_NUM").tiff"
        scanimage -d "$SCANNER" --format tiff > "$TMP_FILE"
        if [[ $? -ne 0 ]]; then
            echo "Scan failed! Please check the scanner and try again."
            rm -f "$TMP_FILE"
            continue  # retry the same page number
        fi
        echo "Page $PAGE_NUM scanned."

        ((PAGE_NUM++))

        echo -n "Press 1 to scan another page, 2 to finish and merge: "
        read -n1 CHOICE
        echo    # move to new line

        if [[ "$CHOICE" == "2" ]]; then
            break
        fi
    done

    OUTFILE="$(timestamp)_multi.pdf"
    echo "Merging pages into $OUTFILE..."
    magick "$TMP_DIR"/page_*.tiff "$OUTFILE"
    echo "Saved as $OUTFILE"

    rm -r "$TMP_DIR"
}

# Main menu
main_menu() {
    while true; do
        echo
        echo "Main Menu"
        echo "1 - Scan single page"
        echo "2 - Scan multi-page document"
        echo "q - Quit"
        echo -n "Choose an option: "
        read -n1 OPTION
        echo    # move to new line

        case "$OPTION" in
            1) scan_single ;;
            2) scan_multi ;;
            q|Q) echo "Goodbye!"; break ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# Entry point
choose_scanner
main_menu
