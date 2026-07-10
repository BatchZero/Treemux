//
//  ImagePreviewView.swift
//  Treemux

import SwiftUI

struct ImagePreviewView: View {
    @Environment(ThemeManager.self) private var theme
    let path: String
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.paneBackground)
    }
}
