# Remote Server Group Reordering Implementation Plan

**Goal:** Allow remote server headers to be reordered independently from workspace rows and persist the order across launches.

**Architecture:** Persist remote group keys in workspace state. A pure ordering helper merges saved keys with currently discovered keys, while `WorkspaceStore` owns mutations and cache invalidation. `SidebarCoordinator` uses a dedicated pasteboard payload for header-only root drops.

## Tasks

- [ ] Add backward-compatible persistence and ordering tests.
- [ ] Implement saved-order merge, stale-key pruning, and forward/backward moves in `WorkspaceStore`.
- [ ] Add a dedicated remote-header drag type and root-level drop handling in `SidebarCoordinator`.
- [ ] Verify collapse/selection preservation and existing workspace-row drag behavior.
- [ ] Run focused tests, the full suite, and a Debug build.
