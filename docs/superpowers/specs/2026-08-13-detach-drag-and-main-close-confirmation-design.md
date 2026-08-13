# Detach Drag and Main-Window Close Confirmation Design

## Goal

Make sidebar tear-off work through real drag completion and prevent the main
window from unexpectedly closing every detached child window.

## Current Root Causes

`SidebarCoordinator` implements
`tableView:draggingSession:endedAtPoint:operation:`, but `NSOutlineView` sends
`outlineView:draggingSession:endedAtPoint:operation:` to its delegate. The
existing selector test therefore validates a callback that the live outline
view never invokes.

Main-window shutdown currently begins from `NSWindow.willCloseNotification`.
That notification is delivered after the close can be cancelled, so
`WindowManager` immediately cascade-closes every child and terminates the app
without warning.

## Drag Behavior

- Implement the exact `NSOutlineViewDelegate` drag-ended callback.
- Decode the existing `DetachedNodeRef` pasteboard payload and route it through
  the existing `onDetachNode` closure and `WindowManager.detach(_:)` path.
- Detach only when no in-outline reorder operation completed and the release
  point is outside the outline view.
- A release over the main detail area or outside all Treemux windows detaches.
- A valid sidebar reorder, or an invalid release that remains inside the
  sidebar, does not detach.

## Main-Window Close Behavior

- Give the main `NSWindow` a delegate that can decide whether it should close
  before `willCloseNotification` fires.
- If no detached child windows exist, allow the current close behavior without
  an additional prompt.
- If detached child windows exist, show a native warning containing the number
  of affected windows.
- The default safe action is **Cancel**. It leaves the main window, child
  windows, and detached-node state untouched.
- The destructive action is **Close All Windows**. It allows the main window
  close to continue, after which the existing cascade shutdown closes the
  children and quits Treemux.
- If a later unsaved-file quit prompt is cancelled, rebuild both the main
  window and the persisted detached child windows so no project remains hidden
  without a corresponding child window.

## Localization and UI

All new alert text and button labels use localization keys and include both
English source text and Simplified Chinese translations in
`Treemux/Localizable.xcstrings`. The alert uses standard AppKit warning styling
and marks **Close All Windows** as destructive.

## Test Strategy

Follow red-green TDD with focused tests for:

1. `SidebarCoordinator` responding to the real `NSOutlineViewDelegate`
   selector and not the mistaken table-view selector.
2. The drag completion decision: outside/sidebar-detail releases detach, while
   completed reorders and releases inside the sidebar do not.
3. Main-window close policy allowing an immediate close with zero children.
4. Main-window close policy cancelling or confirming when children exist.
5. Cancellation leaving all contexts and detached refs intact.
6. Recovery after a later termination cancellation restoring the main window
   and detached children.
7. Existing detach lifecycle tests, the full test suite, a Debug build, and a
   manual interaction pass for drag tear-off and the close confirmation alert.

## Scope

This change does not alter sidebar reorder semantics, detached-window content,
or normal child-window close restoration. It does not add a preference for
disabling the confirmation.
