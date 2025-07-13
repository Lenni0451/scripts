#!/bin/bash

# Usage:
#   ./split_pdfs.sh          # output in subfolders (default)
#   ./split_pdfs.sh --flat   # output all pages in one folder

FLAT_MODE=false
if [ "$1" == "--flat" ]; then
    FLAT_MODE=true
fi

# Check for pdftk or qpdf
if command -v pdftk >/dev/null 2>&1; then
    SPLITTER=pdftk
elif command -v qpdf >/dev/null 2>&1; then
    SPLITTER=qpdf
else
    echo "Error: Neither pdftk nor qpdf is installed."
    exit 1
fi

# Create output directory
mkdir -p split_output

# Process each PDF file in current directory
for pdf in *.pdf; do
    [ -e "$pdf" ] || continue
    filename="${pdf%.*}"
    echo "Splitting $pdf..."

    if [ "$FLAT_MODE" = false ]; then
        mkdir -p "split_output/$filename"
        OUTDIR="split_output/$filename"
        NAME_PREFIX="page_"
    else
        OUTDIR="split_output"
        NAME_PREFIX="${filename}_page_"
    fi

    if [ "$SPLITTER" = "pdftk" ]; then
        pdftk "$pdf" burst output "$OUTDIR/${NAME_PREFIX}%04d.pdf"
    else
        pages=$(qpdf --show-npages "$pdf")
        for i in $(seq 1 "$pages"); do
            qpdf "$pdf" --pages "$pdf" "$i" -- "$OUTDIR/${NAME_PREFIX}$(printf "%04d" "$i").pdf"
        done
    fi
done

echo "Done. Split PDFs are in the 'split_output/' directory."
