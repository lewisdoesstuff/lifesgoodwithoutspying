#!/usr/bin/env bash
# Build the .ipk package.
#
# Requires ares-package (ares-cli-rs or @webos-tools/cli) on PATH.
#   brew install webosbrew/tap/ares-cli-rs   # or see webosbrew.org/develop
#
# Usage: ./build.sh [output-dir]   (default: dist)

set -euo pipefail
cd "$(dirname "$0")"

OUT_DIR="${1:-dist}"

if ! command -v ares-package >/dev/null 2>&1; then
  echo "ares-package not found on PATH. See https://www.webosbrew.org/develop/guides/env-setup" >&2
  exit 1
fi

# Render the icons from the source SVG so app/*.png cannot go stale.
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 80 -h 80 assets/icon.svg -o app/icon.png
  rsvg-convert -w 130 -h 130 assets/icon.svg -o app/largeIcon.png
else
  echo "note: rsvg-convert not found; packaging existing app/icon.png and app/largeIcon.png" >&2
fi

# Build the optional DNS filter bundle with Bun when it is available. The
# generated files are copied into the app only for this package build; the
# canonical source remains under dns-filter/.
DNS_INIT_SOURCE="dns-filter/scripts/tv-handoff.sh"
DNS_INIT_TARGET="app/init/nospy-dns-filter.sh"
DNS_BUNDLE_TARGET="app/init/nospy-dns-filter.js"
rm -f "$DNS_INIT_TARGET" "$DNS_BUNDLE_TARGET"
if [ -f dns-filter/package.json ]; then
    if command -v bun >/dev/null 2>&1; then
        (cd dns-filter && bun install --frozen-lockfile && bun run build)
        cp "$DNS_INIT_SOURCE" "$DNS_INIT_TARGET"
        cp dns-filter/dist/nospy-dns-filter.js "$DNS_BUNDLE_TARGET"
        chmod 755 "$DNS_INIT_TARGET"
        chmod 644 "$DNS_BUNDLE_TARGET"
        echo "DNS filter bundle included"
    else
        echo "note: Bun not found; DNS filter toggle will be unavailable in this package"
    fi
fi

# run-parts only runs executable files; make sure the hooks carry the bit.
chmod +x app/init/nospy-*

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

ares-package -o "$OUT_DIR" app

echo
echo "Built:"
ls -1 "$OUT_DIR"/*.ipk
echo
echo "sha256 (needed for the Homebrew Channel remote install):"
shasum -a 256 "$OUT_DIR"/*.ipk 2>/dev/null || sha256sum "$OUT_DIR"/*.ipk
