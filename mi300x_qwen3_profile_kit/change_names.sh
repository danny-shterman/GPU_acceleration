#!/usr/bin/env bash
set -euo pipefail

# Ensure both input strings are passed
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <string1> <exclude_string> [target_directory]"
    exit 1
fi

INSERT_STR="$1"
EXCLUDE_STR="$2"

# Target directory defaults to $3, or 'results' if it exists, or current directory '.'
if [ -n "${3:-}" ]; then
    TARGET_DIR="$3"
elif [ -d "results" ]; then
    TARGET_DIR="results"
else
    TARGET_DIR="."
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' does not exist."
    exit 1
fi

# -depth processes children before parent directories
find "$TARGET_DIR" -depth -mindepth 1 | while IFS= read -r item; do
    dir=$(dirname "$item")
    base=$(basename "$item")

    # Skip if the name contains the exclude string
    if [ -n "$EXCLUDE_STR" ] && [[ "$base" == *"$EXCLUDE_STR"* ]]; then
        echo "Excluding '$base' (matches exclude string '$EXCLUDE_STR')"
        continue
    fi

    # Match: prefix ([a-z_]+) followed by '_' and suffix ([0-9_]+), plus optional extension (.ext)
    if [[ "$base" =~ ^([a-z_]+)_([0-9_]+)(\..+)?$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]}"
        ext="${BASH_REMATCH[3]:-}"

        new_name="${prefix}_${INSERT_STR}_${suffix}${ext}"
        new_path="$dir/$new_name"

        if [ -e "$new_path" ]; then
            echo "Skipping '$item' -> target already exists: '$new_name'"
        else
            echo "Renaming '$base' -> '$new_name'"
            mv "$item" "$new_path"
        fi
    fi
done