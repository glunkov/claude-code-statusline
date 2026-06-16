#!/bin/bash
# Install the Claude Code statusline on this machine.
# Copies statusline.sh into ~/.claude/ and adds the statusLine key to settings.json
# (with a backup, without overwriting the rest of the config). Requires jq.
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
SRC="$(cd "$(dirname "$0")" && pwd)/statusline.sh"

command -v jq >/dev/null || {
  echo "✗ jq is required (macOS: brew install jq · Debian/Ubuntu: apt install jq · Fedora: dnf install jq · Arch: pacman -S jq)"
  exit 1
}

mkdir -p "$CLAUDE_DIR"
cp "$SRC" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"
echo "✓ statusline.sh → $CLAUDE_DIR/"

SL='{"type":"command","command":"~/.claude/statusline.sh","padding":0,"refreshInterval":60}'

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  jq --argjson sl "$SL" '.statusLine = $sl' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "✓ statusLine key added to settings.json (backup created alongside)"
else
  echo "{\"statusLine\": $SL}" | jq . > "$SETTINGS"
  echo "✓ created $SETTINGS with statusLine"
fi

echo ""
echo "Done. Restart Claude Code and accept the trust dialog."
echo "Manual test:"
echo "  echo '{\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":42,\"remaining_percentage\":58}}' | ~/.claude/statusline.sh"
