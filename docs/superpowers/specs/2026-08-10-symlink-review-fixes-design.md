# Symlink Review Fixes Design

## Goal

Correct the three actionable findings from the symlink-directory review without
changing the feature's public behavior or expanding its scope.

## Scope

The fix covers:

1. cycle detection when the file-browser root is `/` or contains redundant
   trailing separators;
2. actual cancellation of controller-owned directory expansion work;
3. lossless system-SSH canonical directory identities for paths containing
   leading or trailing whitespace and newlines.

It does not redesign directory loading, add transfer behavior, or change the
existing four-request Citadel concurrency bound.

## Design

### Normalized ancestry traversal

`FileBrowserTabController` will normalize both the configured root and the
candidate path before walking parents. Root containment will use path-component
boundaries and explicitly support `/`, avoiding the current `"//"` prefix.
Cycle validation will continue to compare only canonical identities in the
current displayed ancestry, so aliases in separate branches remain valid.

### Controller-owned expansion cancellation

The controller will own one expansion task per displayed path. Starting an
expansion records the task together with its existing request token. A second
toggle, a tree refresh, or a replacement request cancels the stored task and
invalidates the token. Completion cleanup will check the token so an older task
cannot remove a newer operation.

Cancellation propagates into `listDirectory` and the bounded Citadel symlink
resolver. Citadel requests already in flight may depend on the library and
server for prompt cancellation, but cancellation will prevent additional
symlink resolutions from being scheduled and all stale results remain ignored.

### Lossless SSH canonical identities

The system-SSH canonical-identity command will no longer return an unframed
plain-text path that Swift trims. The remote shell will append a non-newline
sentinel before command substitution, remove only that sentinel, hex-encode the
exact path bytes, and return a structured record. Swift will decode the hex
payload and reject malformed or empty responses.

This preserves legal leading/trailing spaces, tabs, and newline characters while
remaining compatible with the portable shell tools already used by the symlink
probe.

## Error handling

- A malformed SSH canonical response produces the existing
  `SFTPServiceError.commandFailed` path.
- Cancellation is treated as a silent stale operation and does not create a row
  error or global load banner.
- Genuine directory-listing errors continue through the existing `mapError`
  behavior when the request is still current.

## Testing

Tests will be added before production changes and observed failing for the
expected reasons:

1. a nested symlink cycle under root `/` is rejected before `listDirectory`;
2. cancelling a controller expansion prevents the data source from continuing
   its queued work and prevents stale state changes;
3. the SSH canonical command/parser round-trips paths with leading/trailing
   spaces, tabs, and newlines.

After each focused red-green cycle, all symlink-focused tests, the complete test
suite, and a standard Debug build will be run. The branch remains
`codex/feat/symlink-directory-support` in its existing worktree.
