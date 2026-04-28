//
//  ImagePreviewView.swift
//  Treemux

import SwiftUI

struct ImagePreviewView: View {
    let path: String
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.05))
    }
}
