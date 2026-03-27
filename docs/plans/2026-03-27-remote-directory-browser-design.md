# Remote Directory Browser Design

## Overview

Replace the manual path input for remote SSH repositories with a visual directory browser, providing a UX consistent with local folder selection (NSOpenPanel-style).

## Problem

Currently, adding a remote repository requires users to manually type the full remote path (e.g., `/home/user/project`). Local repositories use NSOpenPanel for folder selection. This inconsistency makes the remote experience significantly worse.

## Solution

Add an SFTP-based remote directory browser that mirrors the local "path input + Choose... button" pattern.

## Decisions

| Dimension | Decision |
|-----------|----------|
| SFTP library | Citadel (pure Swift, async/await, SwiftNIO-based) |
| UI interaction | Path input field + "Choose..." button, matching local mode |
| Directory browser | Sheet modal, tree-style directory view + path bar |
| Initial directory | User's home directory, with path bar for manual navigation |
| Display content | Directories only, no files |
| Loading strategy | Lazy-load on expand |
| Authentication | Reuse SSHTarget info; private key first, fallback to password |
| Multi-repository | Same as local — one server can have multiple repositories |
| Worktree / icons | Same handling as local repositories |
| UI implementation | Use /ui-ux-pro-max skill |

## Architecture

### New Files

```
Services/SFTP/
├── SFTPService.swift              # Actor: SFTP connection & directory operations
└── SFTPDirectoryEntry.swift       # Remote directory entry model

UI/Sheets/
└── RemoteDirectoryBrowser.swift   # View + ViewModel for remote directory browsing
```

### Modified Files

```
UI/Sheets/OpenProjectSheet.swift   # Add "Choose..." button to remote mode
Project config                     # Add Citadel SPM dependency
```

### Data Flow

```
User clicks "Choose..." button
    ↓
RemoteDirectoryBrowser (Sheet) opens
    ↓
SFTPService connects to SSH Target via Citadel
    ↓
Lists home directory subdirectories
    ↓
User expands/clicks directory → SFTPService lazy-loads children
    ↓
User navigates via path bar → jumps to specified path
    ↓
User selects directory, clicks "Open"
    ↓
Path returned to OpenProjectSheet path input field
    ↓
Existing flow continues (addRemoteWorkspace)
```

## Data Models

### SFTPDirectoryEntry

```swift
struct SFTPDirectoryEntry: Identifiable, Comparable {
    let id = UUID()
    let name: String        // Directory name
    let path: String        // Full path
    let isDirectory: Bool   // Always true (directories only)
}
```

### DirectoryNode (Tree)

```swift
class DirectoryNode: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let path: String
    @Published var children: [DirectoryNode]?  // nil = not loaded
    @Published var isLoading: Bool = false
}
```

## SFTPService

```swift
actor SFTPService {
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

    func connect(target: SSHTarget) async throws
    func listDirectories(at path: String) async throws -> [SFTPDirectoryEntry]
    func homeDirectory() async throws -> String
    func disconnect() async
}
```

- `connect()`: Uses Citadel's `SSHClient.connect()` + key/password auth, then opens SFTP subsystem
- `listDirectories()`: Calls `sftpClient.listDirectory()`, filters to directories only, excludes `.`, `..`, and hidden dirs, sorts by name
- `homeDirectory()`: Resolves `~` via SFTP
- Actor isolation ensures concurrency safety

## RemoteDirectoryBrowser UI

```
┌─────────────────────────────────────────┐
│  Select Remote Directory           ✕    │
├─────────────────────────────────────────┤
│  Path: [ /home/user/projects        ]   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ 📁 Documents                     │   │
│  │ 📁 projects                      │   │
│  │   ├── 📁 treemux                 │   │
│  │   ├── 📁 liney                   │   │
│  │   └── 📁 dotfiles               │   │
│  │ 📁 workspace                     │   │
│  └─────────────────────────────────┘   │
│                                         │
│  Selected: /home/user/projects/treemux  │
│                        [Cancel] [Open]  │
└─────────────────────────────────────────┘
```

### ViewModel

```swift
@MainActor
class RemoteDirectoryBrowserViewModel: ObservableObject {
    @Published var currentPath: String = ""
    @Published var rootEntries: [DirectoryNode] = []
    @Published var selectedPath: String? = nil
    @Published var isConnecting: Bool = false
    @Published var error: String? = nil

    private let sftpService = SFTPService()
    private let sshTarget: SSHTarget

    func connect() async
    func navigateTo(path: String) async
    func expandNode(_ node: DirectoryNode) async
    func disconnect() async
}
```

### Interactions

- **Path bar**: Editable text field; press Enter to navigate; directory tree syncs
- **Directory tree**: SwiftUI `List` + `DisclosureGroup`; lazy-load on expand with `ProgressView`
- **Selection**: Single-click highlights; bottom bar shows selected path
- **Open button**: Enabled when a directory is selected; closes browser and returns path
- **Error handling**: Inline error display with retry button

## OpenProjectSheet Changes

Remote mode UI changes from:
- SSH target dropdown + path text field

To:
- SSH target dropdown + **path input field + "Choose..." button**

"Choose..." button is disabled until an SSH target is selected.

## Authentication Strategy

```
1. identityFile in SSHTarget → private key auth
   - Read key file; prompt for passphrase if encrypted

2. No identityFile → try default key paths
   - ~/.ssh/id_ed25519, ~/.ssh/id_rsa, etc.

3. All key auth fails → fallback to password auth
   - Show password input dialog
```

## Error Handling

| Scenario | Handling |
|----------|----------|
| Connection timeout | Error message + retry button |
| Auth failure | Prompt for correct credentials |
| Permission denied (unreadable dir) | Lock icon + tooltip on node |
| Network disconnect | Disconnection notice + reconnect button |

## Citadel Integration

- Add via SPM: `https://github.com/orlandos-nl/Citadel`
- Brings SwiftNIO, swift-crypto as transitive dependencies
- Pure Swift — no C/ObjC bridging needed
