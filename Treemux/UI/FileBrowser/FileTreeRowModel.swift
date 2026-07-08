//
//  FileTreeRowModel.swift
//  Treemux

import Foundation

/// Value snapshot of one visible file-tree row. The tree view renders from
/// a flat `[FileTreeRowModel]` computed by the controller, so each row view
/// can be Equatable-skipped instead of observing the whole controller.
struct FileTreeRowModel: Equatable, Identifiable {
    enum Kind: Equatable {
        case node(FileNode)
        case loadMore(parentPath: String)
    }

    let id: String
    let kind: Kind
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    let status: FileStatus?
}
