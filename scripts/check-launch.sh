#!/usr/bin/env bash
# Fails, naming each file:line, when a Swift source other than Sources/GHTouchID/Launch.swift starts a program or
# copies a string for one itself. A C string ends at its first NUL, so a NUL inside an argument would cut it short
# after every check had read it whole; Launch.swift is the one place that converts strings for programs, and it
# refuses NUL there, so every launch must go through it for the refusal to hold everywhere. `just lint` runs this.
#
#   scripts/check-launch.sh
set -euo pipefail

cd "$(dirname "$0")/.."

found=0
for file in Sources/GHTouchID/*.swift; do
  [ "$file" = Sources/GHTouchID/Launch.swift ] && continue
  if grep -nE 'strdup\(|posix_spawn|execv\(|execvp\(|Process\(\)' "$file" | sed "s|^|$file:|" >&2; then
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  echo "check-launch.sh: start programs only through the helpers in Sources/GHTouchID/Launch.swift" >&2
  exit 1
fi
