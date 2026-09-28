#!/bin/bash

# Usage:
#   ./decrypt_pdf.sh [options] <input.pdf> [output.pdf]
#   ./decrypt_pdf.sh [options] <file1.pdf> <file2.pdf> ...
#
# Options:
#   -p, --password <password>   Specify the PDF password
#   -o, --output <file>         Specify the output file path
#   -i, --in-place              Overwrite the input file in place
#   -h, --help                  Show help message

set -euo pipefail

print_help() {
  cat << 'EOF'
Usage:
  ./decrypt_pdf.sh [OPTIONS] <input.pdf> [output.pdf]
  ./decrypt_pdf.sh [OPTIONS] <file1.pdf> <file2.pdf> ...

Decrypt password-protected PDF files and remove all passwords and restrictions.

Options:
  -p, --password <pwd>   Provide the password directly.
                         If omitted, you will be prompted securely if the file requires one.
  -o, --output <file>    Specify the output filename (only valid when processing a single file).
  -i, --in-place         Overwrite the original PDF with the decrypted version.
  -h, --help             Show this help message.

Examples:
  ./decrypt_pdf.sh protected.pdf
  ./decrypt_pdf.sh protected.pdf unlocked.pdf
  ./decrypt_pdf.sh -p "secret123" protected.pdf
  ./decrypt_pdf.sh -i protected.pdf
  ./decrypt_pdf.sh -i *.pdf
EOF
}

# Ensure qpdf is installed
if ! command -v qpdf >/dev/null 2>&1; then
  echo "Error: 'qpdf' is not installed." >&2
  echo "Please install it using your system package manager (e.g., sudo apt install qpdf / pacman -S qpdf / dnf install qpdf)." >&2
  exit 1
fi

PASSWORD=""
PASSWORD_SET=false
EXPLICIT_OUTPUT=""
IN_PLACE=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    -p|--password)
      if [[ -z "${2:-}" || "$2" == -* ]]; then
        echo "Error: Option $1 requires a password argument." >&2
        exit 1
      fi
      PASSWORD="$2"
      PASSWORD_SET=true
      shift 2
      ;;
    --password=*)
      PASSWORD="${1#*=}"
      PASSWORD_SET=true
      shift
      ;;
    -o|--output)
      if [[ -z "${2:-}" || "$2" == -* ]]; then
        echo "Error: Option $1 requires an output file path." >&2
        exit 1
      fi
      EXPLICIT_OUTPUT="$2"
      shift 2
      ;;
    --output=*)
      EXPLICIT_OUTPUT="${1#*=}"
      shift
      ;;
    -i|--in-place)
      IN_PLACE=true
      shift
      ;;
    --)
      shift
      POSITIONAL+=("$@")
      break
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      echo "Use -h or --help for usage information." >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
  print_help
  exit 1
fi

if [[ -n "$EXPLICIT_OUTPUT" && ${#POSITIONAL[@]} -gt 1 ]]; then
  echo "Error: -o / --output cannot be used when multiple input files are specified." >&2
  exit 1
fi

if [[ -n "$EXPLICIT_OUTPUT" && "$IN_PLACE" = true ]]; then
  echo "Error: --output and --in-place cannot be used together." >&2
  exit 1
fi

# Determine files and corresponding output targets
declare -a INPUT_FILES=()
declare -a OUTPUT_FILES=()

if [[ -n "$EXPLICIT_OUTPUT" ]]; then
  INPUT_FILES=("${POSITIONAL[0]}")
  OUTPUT_FILES=("$EXPLICIT_OUTPUT")
elif [[ "$IN_PLACE" = true ]]; then
  for f in "${POSITIONAL[@]}"; do
    INPUT_FILES+=("$f")
    OUTPUT_FILES+=("$f")
  done
elif [[ ${#POSITIONAL[@]} -eq 2 && ! -d "${POSITIONAL[1]}" ]]; then
  # Two arguments without -i: treat as <input.pdf> <output.pdf>
  INPUT_FILES=("${POSITIONAL[0]}")
  OUTPUT_FILES=("${POSITIONAL[1]}")
else
  for f in "${POSITIONAL[@]}"; do
    INPUT_FILES+=("$f")
    if [[ "$f" == *.pdf ]]; then
      OUTPUT_FILES+=("${f%.pdf}_decrypted.pdf")
    else
      OUTPUT_FILES+=("${f}_decrypted.pdf")
    fi
  done
fi

decrypt_single_file() {
  local in_file="$1"
  local out_file="$2"

  if [[ ! -f "$in_file" ]]; then
    echo "Error: Input file '$in_file' not found." >&2
    return 1
  fi

  # Ensure target directory exists
  local target_dir
  target_dir="$(dirname "$out_file")"
  if [[ -n "$target_dir" && ! -d "$target_dir" ]]; then
    mkdir -p "$target_dir"
  fi

  # Create a temporary output file to ensure atomic replacement and avoid corrupting original
  local temp_file
  temp_file="$(mktemp "${target_dir:-.}/.decrypt_tmp.XXXXXXXXXX.pdf")"
  # Trap cleanup for unexpected exits
  trap 'rm -f "$temp_file"' RETURN

  local decrypt_success=false
  local current_pass="$PASSWORD"

  if [[ "$PASSWORD_SET" = true ]]; then
    if printf '%s' "$current_pass" | qpdf --password-file=- --decrypt "$in_file" "$temp_file" 2>/dev/null; then
      decrypt_success=true
    else
      echo "Error: Decryption failed for '$in_file'. Incorrect password or invalid PDF." >&2
      return 1
    fi
  else
    # First attempt: Try decrypting without password (handles owner passwords / restrictions)
    local err_output
    if err_output=$(qpdf --decrypt "$in_file" "$temp_file" 2>&1); then
      decrypt_success=true
    else
      # If decryption failed because a password is required, prompt for it
      if echo "$err_output" | grep -qi "password"; then
        local prompt_pass=""
        if [[ -t 0 ]]; then
          read -s -r -p "Enter PDF password for '$in_file': " prompt_pass
          echo ""
        else
          if ! IFS= read -r prompt_pass; then
            echo "Error: Password required for '$in_file' but reached EOF on standard input." >&2
            return 1
          fi
        fi

        if printf '%s' "$prompt_pass" | qpdf --password-file=- --decrypt "$in_file" "$temp_file" 2>/dev/null; then
          decrypt_success=true
        else
          echo "Error: Incorrect password for '$in_file'." >&2
          return 1
        fi
      else
        echo "Error: qpdf failed on '$in_file':" >&2
        echo "$err_output" >&2
        return 1
      fi
    fi
  fi

  if [[ "$decrypt_success" = true ]]; then
    mv -f "$temp_file" "$out_file"
    echo "Decrypted: '$in_file' -> '$out_file'"
    return 0
  fi

  return 1
}

overall_exit=0
for i in "${!INPUT_FILES[@]}"; do
  in="${INPUT_FILES[$i]}"
  out="${OUTPUT_FILES[$i]}"
  if ! decrypt_single_file "$in" "$out"; then
    overall_exit=1
  fi
done

exit "$overall_exit"
