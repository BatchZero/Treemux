# App Icon Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a custom application icon to Treemux from a provided SVG design.

**Architecture:** Convert the SVG to a 1024x1024 PNG, place it in a new `Assets.xcassets/AppIcon.appiconset/`, and wire the asset catalog into the Xcode project file. The existing build setting `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` already matches.

**Tech Stack:** rsvg-convert (SVG→PNG), Xcode Asset Catalog, pbxproj manual editing

---

### Task 1: Convert SVG to 1024x1024 PNG

**Files:**
- Create: `Treemux/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png`

**Step 1: Create directory structure**

```bash
mkdir -p Treemux/Assets.xcassets/AppIcon.appiconset
```

**Step 2: Write the SVG to a temp file**

```bash
cat > /tmp/treemux-icon.svg << 'SVGEOF'
<svg width="256" height="256" viewBox="0 0 256 256" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="256" height="256" rx="52" fill="#0B0F14"/>
  <path d="M128 56L72 168H104L128 120L152 168H184L128 56Z" fill="#58A6FF"/>
</svg>
SVGEOF
```

**Step 3: Convert SVG to 1024x1024 PNG**

```bash
rsvg-convert -w 1024 -h 1024 /tmp/treemux-icon.svg -o Treemux/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png
```

**Step 4: Verify the output**

```bash
sips -g pixelWidth -g pixelHeight Treemux/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png
```

Expected: pixelWidth: 1024, pixelHeight: 1024

---

### Task 2: Create Asset Catalog JSON files

**Files:**
- Create: `Treemux/Assets.xcassets/Contents.json`
- Create: `Treemux/Assets.xcassets/AppIcon.appiconset/Contents.json`

**Step 1: Create the root Asset Catalog Contents.json**

Write `Treemux/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

**Step 2: Create the AppIcon.appiconset Contents.json**

Write `Treemux/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "app-icon-1024.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

---

### Task 3: Wire Asset Catalog into Xcode project

**Files:**
- Modify: `Treemux.xcodeproj/project.pbxproj`

Three edits are needed in `project.pbxproj`:

**Step 1: Add PBXFileReference for Assets.xcassets**

In the `/* Begin PBXFileReference section */`, add a new entry. Use a unique 24-char hex ID (e.g., `A1B2C3D4E5F6A7B8C9D0E1F2`):

```
A1B2C3D4E5F6A7B8C9D0E1F2 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
```

**Step 2: Add Assets.xcassets to the Treemux group's children**

In the Treemux PBXGroup (`3A68A8398041C9097733E6F0`, around line 304), add the file reference to the children array:

```
A1B2C3D4E5F6A7B8C9D0E1F2 /* Assets.xcassets */,
```

Add it after `main.swift` and before the `App` group, to keep resources grouped together.

**Step 3: Add PBXBuildFile for Assets.xcassets in Resources**

In the `/* Begin PBXBuildFile section */`, add (use another unique ID, e.g., `F2E1D0C9B8A7F6E5D4C3B2A1`):

```
F2E1D0C9B8A7F6E5D4C3B2A1 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = A1B2C3D4E5F6A7B8C9D0E1F2 /* Assets.xcassets */; };
```

**Step 4: Add to PBXResourcesBuildPhase**

In the Resources build phase (`6209C5E6F10D6D8901B776A2`, around line 598), add to the `files` array:

```
F2E1D0C9B8A7F6E5D4C3B2A1 /* Assets.xcassets in Resources */,
```

**Step 5: Verify the project file is valid**

```bash
plutil -lint Treemux.xcodeproj/project.pbxproj
```

Expected: `Treemux.xcodeproj/project.pbxproj: OK`

---

### Task 4: Build and verify

**Step 1: Build the project**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 2: Commit all changes**

```bash
git add Treemux/Assets.xcassets/ Treemux.xcodeproj/project.pbxproj
git commit -m "feat: add custom app icon"
```
