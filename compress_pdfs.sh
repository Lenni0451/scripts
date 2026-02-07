#!/bin/bash

#!/bin/bash

# Usage: ./compress_pdfs.sh /path/to/input /path/to/output

INPUT_DIR="$1"
OUTPUT_DIR="$2"

# Ensure both arguments are provided
if [[ -z "$INPUT_DIR" || -z "$OUTPUT_DIR" ]]; then
  echo "Usage: $0 /path/to/input /path/to/output"
  exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Loop through all PDFs in the input directory
for input_file in "$INPUT_DIR"/*.pdf; do
  # Skip if no PDF files are found
  [[ -e "$input_file" ]] || continue

  # Extract the filename without the path
  filename=$(basename "$input_file")
  
  # Build the output file path
  output_file="$OUTPUT_DIR/$filename"

  # Run Ghostscript to compress the PDF
  gs -sDEVICE=pdfwrite \
     -dCompatibilityLevel=1.4 \
     -dPDFSETTINGS=/default \
     -dNOPAUSE -dQUIET -dBATCH \
     -sOutputFile="$output_file" "$input_file"

  echo "Compressed: $filename"
done

