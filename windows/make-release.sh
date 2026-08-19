#!/usr/bin/env bash
# Produce dist/Quill-windows-x64.zip. Does not tag, does not touch the Mac app.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
echo
echo "Attach the zip to the existing GitHub release (do not create a newer"
echo "latest tag — that would ping Mac users about a Windows-only bump):"
echo "  gh release upload v$(cat ../VERSION) dist/Quill-windows-x64.zip --clobber"
