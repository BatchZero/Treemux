#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/sparkle_tools.sh"

PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Treemux.xcodeproj}"
SCHEME="${SCHEME:-Treemux}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-treemux}"
TREEMUX_RELEASE_HOME="${TREEMUX_RELEASE_HOME:-$HOME/.treemux_release}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$TREEMUX_RELEASE_HOME/sparkle_private_key}"

mkdir -p "$(dirname "$SPARKLE_PRIVATE_KEY_FILE")"

GENERATE_KEYS_TOOL="$(sparkle_tool_path generate_keys "$ROOT_DIR" "$PROJECT_PATH" "$SCHEME")"
"$GENERATE_KEYS_TOOL" --account "$SPARKLE_KEY_ACCOUNT" >/dev/null
"$GENERATE_KEYS_TOOL" --account "$SPARKLE_KEY_ACCOUNT" -x "$SPARKLE_PRIVATE_KEY_FILE"
chmod 600 "$SPARKLE_PRIVATE_KEY_FILE"

PUBLIC_KEY="$("$GENERATE_KEYS_TOOL" --account "$SPARKLE_KEY_ACCOUNT" -p)"

echo "Sparkle keys are ready."
echo "Account: $SPARKLE_KEY_ACCOUNT"
echo "Private key file: $SPARKLE_PRIVATE_KEY_FILE"
echo "Public key: $PUBLIC_KEY"
echo
echo "Next steps:"
echo "1. Replace PLACEHOLDER_PUBLIC_KEY in Info.plist and project.yml with the public key above."
echo "2. Do NOT commit the private key into the repository."
