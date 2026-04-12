# App Icon Design

## Overview

Add a custom application icon to Treemux using the macOS single-size Asset Catalog approach.

## Icon Design

- Background: `#0B0F14` dark rounded rectangle (rx=52 at 256px, scales to rx≈208 at 1024px)
- Foreground: `#58A6FF` blue upward arrow/triangle
- Source SVG provided by user (256x256 viewBox)

## Approach: Single 1024x1024 PNG (Apple recommended)

Create `Treemux/Assets.xcassets/AppIcon.appiconset/` with a single 1024x1024 PNG. macOS 14+ Asset Catalog handles automatic downscaling.

## Files to Create

```
Treemux/Assets.xcassets/
├── Contents.json
└── AppIcon.appiconset/
    ├── Contents.json
    └── app-icon-1024.png
```

## Xcode Integration

- Add `Assets.xcassets` to `Treemux.xcodeproj` file references and build phases
- Existing build setting `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` already matches

## Out of Scope

- No Info.plist changes
- No Swift code changes
- No multi-size icon generation
