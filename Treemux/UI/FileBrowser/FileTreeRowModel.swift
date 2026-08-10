//
//  FileTreeRowModel.swift
//  Treemux

import Foundation

/// Which kind of entry an inline-editor row will create.
enum NewEntryIntent: Equatable {
    case folder
    case file
}

/// Value snapshot of one visible file-tree row. The tree view renders from
/// a flat `[FileTreeRowModel]` computed by the controller, so each row view
/// can be Equatable-skipped instead of observing the whole controller.
struct FileTreeRowModel: Equatable, Identifiable {
    enum Kind: Equatable {
        case node(FileNode)
        case loadMore(parentPath: String)
        case editor(parentPath: String, intent: NewEntryIntent)
    }

    let id: String
    let kind: Kind
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    let status: FileStatus?
    let symlinkError: String?

    init(
        id: String,
        kind: Kind,
        depth: Int,
        isSelected: Bool,
        isExpanded: Bool,
        status: FileStatus?,
        symlinkError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.depth = depth
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        self.status = status
        self.symlinkError = symlinkError
    }
}
