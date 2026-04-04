#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/repo [/path/to/repo ...]" >&2
  exit 1
fi

entries=(
  ".DS_Store"
  "**/.DS_Store"
)

for repo in "$@"; do
  if [[ ! -d "$repo/.git" ]]; then
    echo "Skipping $repo: not a git repository" >&2
    continue
  fi

  gitignore="$repo/.gitignore"
  touch "$gitignore"

  for entry in "${entries[@]}"; do
    if ! grep -qxF "$entry" "$gitignore"; then
      printf '%s\n' "$entry" >> "$gitignore"
    fi
  done

  echo "Updated $gitignore"
done
