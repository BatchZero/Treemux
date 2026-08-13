# Full-Screen Toolbar Transition Theme Design

## Goal

Prevent the native macOS toolbar from flashing white while a dark-themed Treemux window enters full screen, without changing the native toolbar layout or full-screen animation.

## Root Cause

Treemux currently reapplies its theme to AppKit's rebuilt titlebar container only from `windowDidEnterFullScreen`. That callback runs after the transition, so the final full-screen state is correct but AppKit's default white titlebar background remains visible during the animation.

## Design

Keep `refreshFullScreenTitlebar()` as the single theme synchronization path. Call it from `windowWillEnterFullScreen` before AppKit starts the transition, while retaining the existing `windowDidEnterFullScreen` calls as post-transition fallbacks. This preserves the standard `NSWindow`/`NSToolbar` hierarchy, the leading sidebar button, the “Treemux” title, the trailing toolbar actions, and the system animation.

## Verification

- Add a regression test that resets the titlebar layer to white, invokes `windowWillEnterFullScreen`, and verifies the layer immediately uses the active theme color.
- Keep the existing native toolbar layout and final full-screen titlebar tests.
- Visually inspect the transition from the first animation frame through the settled full-screen state.
- Run the complete macOS test suite and build the Debug app.

