#!/usr/bin/env bash
# Build the Windows Quill binary (cross-compile). Does not touch the Mac app.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd .. && pwd)"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.8.3)"
export PATH="${HOME}/.dotnet:${PATH}"
export DOTNET_ROOT="${HOME}/.dotnet"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet SDK is not installed. User-local install:" >&2
  echo "  curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel 8.0 --install-dir \"\$HOME/.dotnet\"" >&2
  exit 1
fi

python3 src/Quill.App/Assets/make_icon.py

echo "→ tests"
dotnet test tests/Quill.Tests/Quill.Tests.csproj -c Release --nologo

echo "→ publish win-x64 v$VERSION"
rm -rf dist
dotnet publish src/Quill.App/Quill.App.csproj \
  -c Release \
  -r win-x64 \
  --self-contained true \
  -p:Version="$VERSION" \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true \
  -p:DebugType=embedded \
  -o dist/win-x64

# Sanity: this must be a Windows PE file, never a Mach-O that could run on this Mac.
file dist/win-x64/Quill.exe | grep -qi "PE32" || {
  echo "refusing to ship: Quill.exe is not a Windows PE binary" >&2
  file dist/win-x64/Quill.exe >&2
  exit 1
}

( cd dist/win-x64 && zip -qr ../Quill-windows-x64.zip Quill.exe )
echo "✓ dist/Quill-windows-x64.zip  ($(du -h dist/Quill-windows-x64.zip | cut -f1))"
echo "  sha256: $(shasum -a 256 dist/Quill-windows-x64.zip | cut -d' ' -f1)"
echo
echo "Mac Quill was not rebuilt or restarted."
