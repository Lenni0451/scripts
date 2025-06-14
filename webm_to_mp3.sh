#!/bin/bash

mkdir -p conv

for input in *.webm; do
    # Skip if no .webm files are found
    [ -e "$input" ] || continue

    # Remove .webm extension and construct output path
    base_name="${input%.webm}"
    output="conv/${base_name}.mp3"

    echo "Converting: $input -> $output"
    ffmpeg -i "$input" -vn -acodec libmp3lame -q:a 2 "$output"
done

echo "Conversion complete."
