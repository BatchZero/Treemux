//
//  ImagePreviewView.swift
//  Treemux

import SwiftUI

struct ImagePreviewView: View {
    @EnvironmentObject private var theme: ThemeManager
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
