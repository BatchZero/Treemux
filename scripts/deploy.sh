#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_FILE="${PROJECT_FILE:-$ROOT_DIR/Treemux.xcodeproj/project.pbxproj}"
APP_NAME="${APP_NAME:-Treemux}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Treemux.xcodeproj}"
SCHEME="${SCHEME:-Treemux}"
RELEASE_ARCHS="${RELEASE_ARCHS:-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
APPCAST_FILE="${APPCAST_FILE:-$ROOT_DIR/sparkle-feed.xml}"
SIGN_SCRIPT="${SIGN_SCRIPT:-$ROOT_DIR/scripts/sign_macos.sh}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
DEFAULT_NOTARYTOOL_PROFILE="${DEFAULT_NOTARYTOOL_PROFILE:-treemux-notarytool}"
TREEMUX_RELEASE_HOME="${TREEMUX_RELEASE_HOME:-$HOME/.treemux_release}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$TREEMUX_RELEASE_HOME/sparkle_private_key}"
SPARKLE_MAX_VERSIONS="${SPARKLE_MAX_VERSIONS:-10}"
SPARKLE_CHANNEL="${SPARKLE_CHANNEL:-}"
SKIP_BUMP="${SKIP_BUMP:-0}"
BUMP_PART="${BUMP_PART:-patch}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
SKIP_SIGN="${SKIP_SIGN:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-1}"
RELEASE_NOTES_LIMIT="${RELEASE_NOTES_LIMIT:-50}"
RELEASE_NOTES_FILE=""
APPCAST_STAGING_DIR=""

source "$ROOT_DIR/scripts/sparkle_tools.sh"

usage() {
  cat <<EOF
Usage:
  scripts/deploy.sh

Environment:
  SKIP_BUMP=1            Publish the current version unchanged.
  BUMP_PART=patch        Version bump part (major|minor|patch). Default: patch.
  SKIP_NOTARIZE=1        Skip notarization.
  SKIP_SIGN=1            Skip code signing entirely (for unsigned releases).
  TREEMUX_RELEASE_HOME=dir  Release-only secret directory. Default: ~/.treemux_release.
  SPARKLE_PRIVATE_KEY_FILE=path  Private key used for Sparkle appcast signing.
EOF
}

read_setting() {
  local key="$1"
  awk -F ' = ' -v key="$key" '$1 ~ key { gsub(/;/, "", $2); print $2; exit }' "$PROJECT_FILE"
}

infer_release_repo() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$remote" =~ ^git@github\.com:([^/]+/[^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]%.git}"
    return
  fi
  if [[ "$remote" =~ ^https://github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]%.git}"
    return
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

detect_notarytool_profile() {
  local profile="${1:-}"
  [[ -n "$profile" ]] || return 1
  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1
}

detect_signing_identity() {
  security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' |
    head -n 1
}

ensure_clean_worktree() {
  if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "Working tree is not clean. Commit or stash changes before release." >&2
    exit 1
  fi
}

generate_release_notes() {
  local version="$1"
  local tag="$2"
  local previous_tag="$3"
  local dmg_name="$4"
  local release_notes_file
  local log_range
  local commit_count
  local compare_url=""

  release_notes_file="$(mktemp "${TMPDIR:-/tmp}/treemux-release-notes.XXXXXX.md")"

  if [[ -n "$previous_tag" ]]; then
    log_range="$previous_tag..HEAD"
    compare_url="https://github.com/$RELEASE_REPO/compare/$previous_tag...$tag"
  else
    log_range="HEAD"
  fi

  commit_count="$(git rev-list --count $log_range)"
  {
    echo "## Release $version"
    echo
    echo "- DMG: \`$dmg_name\`"
    if [[ -n "$previous_tag" ]]; then
      echo "- Previous release: \`$previous_tag\`"
    else
      echo "- Previous release: none"
    fi
    echo
    echo "## Included Commits"
    echo
    git log \
      --max-count="$RELEASE_NOTES_LIMIT" \
      --pretty=format:'- `%h` %s' \
      $log_range
    if [[ "$commit_count" -gt "$RELEASE_NOTES_LIMIT" ]]; then
      echo
      echo
      echo "_Truncated to the most recent ${RELEASE_NOTES_LIMIT} commits out of ${commit_count}._"
    fi
    if [[ -n "$compare_url" ]]; then
      echo
      echo
      echo "Full diff: $compare_url"
    fi
  } > "$release_notes_file"

  echo "$release_notes_file"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

for cmd in git gh shasum mktemp; do
  require_cmd "$cmd"
done

if [[ -z "$NOTARYTOOL_PROFILE" ]] && detect_notarytool_profile "$DEFAULT_NOTARYTOOL_PROFILE"; then
  NOTARYTOOL_PROFILE="$DEFAULT_NOTARYTOOL_PROFILE"
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Missing Xcode project file: $PROJECT_FILE" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

RELEASE_REPO="${RELEASE_REPO:-$(infer_release_repo)}"
if [[ -z "$RELEASE_REPO" ]]; then
  echo "Unable to infer GitHub repo from origin. Set RELEASE_REPO=owner/repo." >&2
  exit 1
fi

cd "$ROOT_DIR"
ensure_clean_worktree

if [[ ! -f "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  echo "Missing Sparkle private key file: $SPARKLE_PRIVATE_KEY_FILE" >&2
  echo "Run scripts/setup_sparkle_keys.sh first." >&2
  exit 1
fi

VERSION="$(read_setting MARKETING_VERSION)"
TAG="v$VERSION"
DIST_DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"
DIST_ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.app.zip"
RELEASE_DONE=0
PREVIOUS_TAG="$(git tag -l 'v*' --sort=-version:refname | head -n 1 || true)"

cleanup() {
  if [[ "$RELEASE_DONE" -eq 0 ]]; then
    git restore --source=HEAD --staged --worktree -- "$PROJECT_FILE" "$APPCAST_FILE" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RELEASE_NOTES_FILE" && -f "$RELEASE_NOTES_FILE" ]]; then
    rm -f "$RELEASE_NOTES_FILE"
  fi
  if [[ -n "$APPCAST_STAGING_DIR" && -d "$APPCAST_STAGING_DIR" ]]; then
    rm -rf "$APPCAST_STAGING_DIR"
  fi
}
trap cleanup EXIT

# Step 1: Bump version
if [[ "$SKIP_BUMP" != "1" ]]; then
  "$ROOT_DIR/scripts/bump_version.sh" "$BUMP_PART"
  VERSION="$(read_setting MARKETING_VERSION)"
fi

TAG="v$VERSION"
DIST_DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"
DIST_ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.app.zip"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag already exists: $TAG" >&2
  exit 1
fi

# Step 2: Build
if [[ "$SKIP_SIGN" != "1" ]]; then
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(detect_signing_identity)"
  fi

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No signing identity found. Use SKIP_SIGN=1 for unsigned builds." >&2
    exit 1
  fi

  SIGN_ARGS=(
    --identity "$SIGNING_IDENTITY"
    --version "$VERSION"
    --output-dir "$OUTPUT_DIR"
    --release-archs "$RELEASE_ARCHS"
  )
  [[ "$FORCE_REBUILD" == "1" ]] && SIGN_ARGS+=(--force-rebuild)
  [[ "$SKIP_NOTARIZE" != "1" ]] && SIGN_ARGS+=(--notarize)

  NOTARYTOOL_PROFILE="$NOTARYTOOL_PROFILE" \
  PROJECT_PATH="$PROJECT_PATH" \
  SCHEME="$SCHEME" \
  "$SIGN_SCRIPT" "${SIGN_ARGS[@]}"
else
  # Unsigned build
  VERSION="$VERSION" \
  OUTPUT_DIR="$OUTPUT_DIR" \
  RELEASE_ARCHS="$RELEASE_ARCHS" \
  PROJECT_PATH="$PROJECT_PATH" \
  SCHEME="$SCHEME" \
  "$ROOT_DIR/scripts/build_macos_app.sh"

  # Ad-hoc sign so Sparkle generate_appcast can process the archive
  /usr/bin/codesign --force --sign - --deep "$OUTPUT_DIR/$APP_NAME.app"
fi

if [[ ! -f "$DIST_DMG_PATH" ]]; then
  echo "Missing packaged DMG: $DIST_DMG_PATH" >&2
  exit 1
fi

# Step 3: Create Sparkle ZIP and appcast
RELEASE_NOTES_FILE="$(generate_release_notes "$VERSION" "$TAG" "$PREVIOUS_TAG" "$(basename "$DIST_DMG_PATH")")"
sparkle_create_app_zip "$OUTPUT_DIR/$APP_NAME.app" "$DIST_ZIP_PATH"

APPCAST_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/treemux-appcast.XXXXXX")"
ZIP_BASENAME="$(basename "$DIST_ZIP_PATH" .zip)"
cp "$DIST_ZIP_PATH" "$APPCAST_STAGING_DIR/"
cp "$RELEASE_NOTES_FILE" "$APPCAST_STAGING_DIR/$ZIP_BASENAME.md"
if [[ -f "$APPCAST_FILE" ]]; then
  cp "$APPCAST_FILE" "$APPCAST_STAGING_DIR/appcast.xml"
fi

sparkle_generate_appcast \
  "$APPCAST_STAGING_DIR" \
  "$SPARKLE_PRIVATE_KEY_FILE" \
  "https://github.com/$RELEASE_REPO/releases/download/$TAG/" \
  "https://github.com/$RELEASE_REPO/releases/tag/$TAG" \
  "https://github.com/$RELEASE_REPO" \
  "$SPARKLE_MAX_VERSIONS" \
  "$SPARKLE_CHANNEL" \
  "$ROOT_DIR" \
  "$PROJECT_PATH" \
  "$SCHEME"

cp "$APPCAST_STAGING_DIR/appcast.xml" "$APPCAST_FILE"
rm -rf "$APPCAST_STAGING_DIR"

# Step 4: Commit, tag, push
git add -- "$PROJECT_FILE" "$APPCAST_FILE"
if ! git diff --cached --quiet; then
  git commit -m "chore: release $VERSION"
  git push origin "$(git branch --show-current)"
fi

git tag "$TAG"
git push origin "$TAG"

# Step 5: Create or update GitHub release
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DIST_DMG_PATH" "$DIST_ZIP_PATH" "$APPCAST_FILE" --clobber
  gh release edit "$TAG" \
    --title "$APP_NAME $VERSION" \
    --notes-file "$RELEASE_NOTES_FILE"
else
  gh release create "$TAG" "$DIST_DMG_PATH" "$DIST_ZIP_PATH" "$APPCAST_FILE" \
    --title "$APP_NAME $VERSION" \
    --notes-file "$RELEASE_NOTES_FILE"
fi

RELEASE_DONE=1
echo "Done. Released $TAG"
