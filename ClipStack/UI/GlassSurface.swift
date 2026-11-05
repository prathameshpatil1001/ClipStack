//
//  GlassSurface.swift
//  ClipStack
//
//  One surface style for ClipStack's floating windows — the ⌥Space recall panel
//  and the HUD.
//
//  macOS 26 introduced Liquid Glass, which is what a panel floating over someone
//  else's document should be made of: it refracts and reacts to what is behind
//  it rather than merely blurring it. ClipStack still targets macOS 13, so
//  `.regularMaterial` stays as the fallback, and the two live behind one
//  modifier instead of `#available` scattered through the views.
//

import SwiftUI

struct GlassSurface<SurfaceShape: InsettableShape>: ViewModifier {

    let shape: SurfaceShape

    @ViewBuilder
    func body(content: Content) -> some View {
        // `glassEffect` exists only in the macOS 26 SDK (Swift 6.2 and later).
        // Building with an older SDK — CI's Xcode 16 — falls back to the
        // material, as running on an older macOS does.
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    /// Glass draws its own edge; the flat material needs a hairline to
    /// separate it from a light background behind.
    private func material(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

extension View {
    /// Liquid Glass on macOS 26+, `.regularMaterial` below it.
    func glassSurface<SurfaceShape: InsettableShape>(in shape: SurfaceShape) -> some View {
        modifier(GlassSurface(shape: shape))
    }
}
