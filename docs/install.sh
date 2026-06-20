#!/bin/bash
# Stormbreaker CLI installer.
#   curl -fsSL https://parthee-vijaya.github.io/stormbreaker-mac/install.sh | bash
#
# Downloads the prebuilt, standalone `storm` binary from the latest GitHub
# release and drops it on your PATH. No Xcode/Swift toolchain needed, and
# because curl doesn't quarantine downloads there's no Gatekeeper prompt.
set -euo pipefail

REPO="Parthee-Vijaya/stormbreaker-mac"
ASSET="stormbreaker-macos-arm64.tar.gz"
URL="https://github.com/$REPO/releases/latest/download/$ASSET"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "✗ Stormbreaker CLI kører kun på macOS." >&2; exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "✗ Stormbreaker CLI kræver Apple Silicon (arm64)." >&2; exit 1
fi

# First writable dir on PATH wins; otherwise default to ~/.local/bin.
DEST=""
for d in "$HOME/.local/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
  if [ -d "$d" ] && [ -w "$d" ]; then DEST="$d"; break; fi
done
DEST="${DEST:-$HOME/.local/bin}"
mkdir -p "$DEST"

echo "→ Henter storm…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/$ASSET"
tar -xzf "$TMP/$ASSET" -C "$TMP"
chmod +x "$TMP/storm"
xattr -dr com.apple.quarantine "$TMP/storm" 2>/dev/null || true
mv -f "$TMP/storm" "$DEST/storm"
ln -sf "$DEST/storm" "$DEST/stormbreaker"   # samme binær — skriv 'storm' eller 'stormbreaker'

# storm-mcp: the MCP server, so external agents (Claude Code / deepagents / …) can
# drive Stormbreaker. Bundled in the same tarball; install it if present.
if [ -f "$TMP/storm-mcp" ]; then
  chmod +x "$TMP/storm-mcp"
  xattr -dr com.apple.quarantine "$TMP/storm-mcp" 2>/dev/null || true
  mv -f "$TMP/storm-mcp" "$DEST/storm-mcp"
  echo "✓ Installeret: $DEST/storm-mcp  (MCP-server)"
fi

echo "✓ Installeret: $DEST/storm  (også som 'stormbreaker')"
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo
     echo "  $DEST er ikke på din PATH. Tilføj den:"
     echo "    echo 'export PATH=\"$DEST:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac
echo
echo "Kom i gang:"
echo "  storm                  # åbn (= stormbreaker) · skriv / for kommandoer"
echo "  storm new min-app      # nyt projekt"
