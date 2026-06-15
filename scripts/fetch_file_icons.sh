#!/usr/bin/env bash
# Downloads a curated, license-clean icon set into Assets.xcassets imagesets.
# Re-runnable. MDI (Apache-2.0) icons are template-rendering (tinted in code);
# Material Icon Theme (MIT) icons keep their original color.
set -euo pipefail

ASSETS="$(cd "$(dirname "$0")/.." && pwd)/Treemux/Assets.xcassets"
MDI="https://cdn.jsdelivr.net/npm/@mdi/svg@7.4.47/svg"
MAT="https://cdn.jsdelivr.net/gh/material-extensions/vscode-material-icon-theme@main/icons"

MDI_ICONS="folder folder-open link-variant file-document-outline"
MAT_ICONS="swift typescript react javascript python rust go json markdown html css vue nodejs docker git toml lock zip pdf image audio video font prisma"

emit_imageset() { # $1 = name, $2 = base url, $3 = template(true/false)
  local name="$1" base="$2" template="$3"
  local dir="$ASSETS/$name.imageset"
  mkdir -p "$dir"
  curl -fsSL "$base/$name.svg" -o "$dir/$name.svg"
  local props='"preserves-vector-representation" : true'
  if [ "$template" = "true" ]; then
    props="$props, \"template-rendering-intent\" : \"template\""
  fi
  cat > "$dir/Contents.json" <<EOF
{
  "images" : [
    {
      "filename" : "$name.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : { $props }
}
EOF
  echo "  + $name ($([ "$template" = true ] && echo template || echo color))"
}

echo "MDI (template):"
for n in $MDI_ICONS; do emit_imageset "$n" "$MDI" true; done
echo "Material Icon Theme (color):"
for n in $MAT_ICONS; do emit_imageset "$n" "$MAT" false; done
echo "Done. $(echo $MDI_ICONS $MAT_ICONS | wc -w) imagesets in $ASSETS"
