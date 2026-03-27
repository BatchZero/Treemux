# Sidebar Icons Design

## Summary

Port Liney's complete sidebar icon system to Treemux, enabling rich, customizable icons for workspaces (repositories, terminals, remotes) and worktrees in the sidebar.

## Motivation

Treemux currently uses three fixed SF Symbols (`folder.fill`, `apple.terminal`, `globe`) with flat colors for sidebar items. Liney has a mature icon system with 69 symbols, 40+ color palettes, semantic profiling, deduplication, and full user customization. Porting this system will make Treemux's sidebar visually richer and give users control over icon appearance.

## Approach

**Direct port from Liney** — adapt Liney's icon code to Treemux's data model rather than rewriting from scratch.

## Data Model

### New Types (`SidebarIcon.swift`)

```swift
enum SidebarIconFillStyle: String, Codable, Hashable, CaseIterable {
    case solid
    case gradient
}

enum SidebarIconPalette: String, Codable, Hashable, CaseIterable {
    // 40 cases: blue, cyan, aqua, ice, sky, teal, turquoise, mint, green,
    // forest, lime, olive, gold, sand, bronze, amber, orange, copper, rust,
    // coral, peach, brick, crimson, ruby, berry, rose, magenta, orchid,
    // indigo, navy, steel, violet, iris, lavender, plum, slate, smoke,
    // charcoal, graphite, mocha
    //
    // Each case has a `descriptor` property returning SidebarIconPaletteDescriptor
    // with 5 RGBA color values: foreground, solidBackground, gradientStart,
    // gradientEnd, border.
}

struct SidebarIconPaletteDescriptor {
    let foreground: Color
    let solidBackground: Color
    let gradientStart: Color
    let gradientEnd: Color
    let border: Color
}

struct SidebarItemIcon: Codable, Hashable {
    var symbolName: String
    var palette: SidebarIconPalette
    var fillStyle: SidebarIconFillStyle
}
```

### Default Icons

| Kind | Symbol | Palette | Fill |
|------|--------|---------|------|
| Repository | `arrow.triangle.branch` | blue | gradient |
| Local Terminal | `terminal.fill` | teal | solid |
| Remote | `globe` | orange | gradient |
| Worktree | `circle.fill` | mint | solid |

### WorkspaceRecord Changes

```swift
struct WorkspaceRecord: Codable {
    // ... existing fields ...
    let workspaceIcon: SidebarItemIcon?                   // NEW
    let worktreeIconOverrides: [String: SidebarItemIcon]? // NEW (keyed by worktree path)
}
```

Both fields are optional with `decodeIfPresent` for backward compatibility.

### WorkspaceModel Changes

```swift
@Published var workspaceIcon: SidebarItemIcon?
@Published var worktreeIconOverrides: [String: SidebarItemIcon] = [:]
```

### AppSettings Changes

```swift
var defaultRepositoryIcon: SidebarItemIcon = .repositoryDefault
var defaultLocalTerminalIcon: SidebarItemIcon = .localTerminalDefault
var defaultRemoteIcon: SidebarItemIcon = .remoteDefault
var defaultWorktreeIcon: SidebarItemIcon = .worktreeDefault
```

## Icon Catalog (`SidebarIconCatalog.swift`)

### Symbols

69 SF Symbols organized by category: branch, terminal, folder, tray, cube, server, cloud, network, globe, display, laptop, hammer, wrench, bolt, sparkles, briefcase, building, books, document, chart, etc.

### Semantic Profiling

Maps repository names to preferred icons/palettes via keyword matching:

| Category | Keywords | Preferred Symbols | Preferred Palettes |
|----------|----------|-------------------|-------------------|
| API/Backend | api, backend, server, service | server.rack, cpu.fill, network | navy, steel, cyan |
| Web/Frontend | web, ui, frontend, app | globe, sparkles, paintpalette.fill | aqua, sky, orchid |
| Docs | docs, blog, wiki, guide | doc.text.fill, books.vertical.fill | sand, amber, bronze |
| Infra/DevOps | infra, ops, deploy, k8s | wrench.fill, shippingbox.fill | charcoal, steel, graphite |
| Database | data, db, cache, queue | externaldrive.fill, memorychip.fill | aqua, teal, blue |
| Security | auth, security, vault, key | shield.fill, key.fill, lock.doc.fill | ruby, crimson, navy |

### Deduplication

Scoring system penalizes recently used symbols/palettes/pairs and rewards semantic matches. Tracks last 3 icons and frequency counts across all existing icons.

### Stable Hashing

FNV-1a hash + MurmurHash3-style mixing for deterministic, seed-based icon generation.

## Icon Selection Priority

### Workspace Icons

1. `workspace.workspaceIcon` (user override)
2. `appSettings.defaultRepositoryIcon / defaultLocalTerminalIcon / defaultRemoteIcon` (by kind)

### Worktree Icons

1. `workspace.worktreeIconOverrides[worktree.path]` (user override)
2. `appSettings.defaultWorktreeIcon` (if changed from default)
3. `generatedWorktreeIcons()` (semantic + dedup auto-generation)
4. `.randomRepository()` fallback

### Worktree Seed

```
seed = "repositoryName|worktreeDisplayName|worktreePath"
```

Ensures consistent results across app launches while differentiating sibling worktrees.

## Rendering (`SidebarItemIconView.swift`)

```
ZStack(alignment: .bottomTrailing) {
    Image(systemName:)
        .font(size * 0.48, bold)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(palette.foreground)
        .frame(size x size)
        .background(solid or gradient RoundedRectangle, cornerRadius: size * 0.34)
        .overlay(1pt strokeBorder in palette.border)

    if isActive {
        Green circle indicator (size * 0.28), offset bottom-right
    }
}
.frame(size + 2)
```

### Sizes

| Context | Size |
|---------|------|
| Workspace row | 22pt |
| Worktree row | 18pt |
| Editor preview | 26pt |

## Customization UI

### Sheet: `SidebarIconCustomizationSheet`

480pt wide modal sheet containing:

- Title: "Customize Sidebar Icon"
- Subtitle: workspace/worktree name
- `SidebarIconEditorCard`:
  - Icon preview (26pt) + title + Random button
  - Symbol picker (dropdown, 69 options with icon previews)
  - Fill style segmented control (Solid / Gradient)
  - Palette grid (LazyVGrid, 34x24pt gradient swatches, white border on selected)
- Action buttons: Reset / Cancel / Save

### Right-Click Menu Entry

Added to both workspace and worktree context menus:

```
Button { ... } label: {
    Label("Change Icon…", systemImage: "paintpalette")
}
```

### Settings Panel Entry

New "Sidebar Icons" section in SettingsSheet with four `SidebarIconEditorCard` instances:
- Default Repository Icon
- Default Terminal Icon
- Default Remote Icon
- Default Worktree Icon

### Customization Target Model

```swift
enum SidebarIconCustomizationTarget {
    case workspace(UUID)
    case worktree(workspaceID: UUID, worktreePath: String)
    case appDefaultRepository
    case appDefaultLocalTerminal
    case appDefaultRemote
    case appDefaultWorktree
}
```

### Flow

```
Right-click "Change Icon…" or Settings panel
  → store.sidebarIconCustomizationRequest = request
  → .sheet(item:) presents SidebarIconCustomizationSheet
  → User edits → Save
  → store.updateSidebarIcon(icon, for: target)
  → Persist → UI refreshes automatically
```

## File Changes

### New Files (4)

| File | Content | Est. Lines |
|------|---------|-----------|
| `Treemux/Domain/SidebarIcon.swift` | FillStyle + Palette + ItemIcon + PaletteDescriptor | ~350 |
| `Treemux/Domain/SidebarIconCatalog.swift` | Symbol catalog + semantic profiling + dedup + hashing | ~450 |
| `Treemux/UI/Sidebar/SidebarItemIconView.swift` | Icon rendering component | ~60 |
| `Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift` | Editor sheet + EditorCard | ~160 |

### Modified Files (5)

| File | Changes |
|------|---------|
| `WorkspaceModels.swift` | Add icon fields to WorkspaceRecord + WorkspaceModel, update toRecord/init |
| `AppSettings.swift` | Add 4 default icon fields |
| `WorkspaceStore.swift` | Add icon get/update/reset methods + customizationRequest state |
| `WorkspaceSidebarView.swift` | Replace fixed icons with SidebarItemIconView, add context menu + sheet |
| `SettingsSheet.swift` | Add "Sidebar Icons" section |

## Backward Compatibility

- All new `WorkspaceRecord` fields are `Optional`, decoded with `decodeIfPresent`
- All new `AppSettings` fields have default values
- No data migration needed — old JSON loads cleanly with defaults

## Out of Scope

- Icon drag-and-drop reordering
- Icon import/export
- Custom images beyond SF Symbols
