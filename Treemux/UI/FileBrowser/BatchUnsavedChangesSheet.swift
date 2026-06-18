//
//  BatchUnsavedChangesSheet.swift
//  Treemux
//
//  Presented by WorkspaceTabContainerView when the user closes a file-browser
//  outer tab that has 2+ sub-tabs with unsaved edits. Lists the dirty files
//  by their root-relative path and offers Save All / Don't Save / Cancel.
//

import SwiftUI

struct BatchUnsavedChangesSheet: View {
    @EnvironmentObject private var theme: ThemeManager
    let dirtyRelativePaths: [String]
    let onSaveAll: () -> Void
    let onDiscardAll: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String.localizedStringWithFormat(
                String(localized: "%lld files have unsaved changes:"),
                dirtyRelativePaths.count))
                .font(DesignFonts.dialogTitle)
                .tracking(DesignFonts.dialogTitleTracking)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(dirtyRelativePaths, id: \.self) { p in
                        Text(p).font(.system(size: 12, design: .monospaced))   // intentional monospaced: data layer
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 200)
            HStack {
                Button(LocalizedStringKey("Cancel")) { onCancel() }
                    .buttonStyle(UtilityButtonStyle(tint: theme.textSecondary, activeTint: theme.accentColor, border: theme.dividerColor))
                Spacer()
                Button(LocalizedStringKey("Don't Save")) { onDiscardAll() }
                    .buttonStyle(UtilityButtonStyle(tint: theme.textSecondary, activeTint: theme.accentColor, border: theme.dividerColor))
                Button(LocalizedStringKey("Save All")) { onSaveAll() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle(accent: theme.accentColor, onAccent: theme.onAccentColor))
            }
        }
        .padding(Spacing.lg)
        .frame(width: 420)
    }
}
