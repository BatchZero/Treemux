//
//  SidebarIcon.swift
//  Treemux
//

import SwiftUI

// MARK: - SidebarIconFillStyle

enum SidebarIconFillStyle: String, Codable, Hashable, CaseIterable, Identifiable {
    case solid
    case gradient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid:
            return "Solid"
        case .gradient:
            return "Gradient"
        }
    }
}

// MARK: - SidebarIconPalette

enum SidebarIconPalette: String, Codable, Hashable, CaseIterable, Identifiable {
    case blue
    case cyan
    case aqua
    case ice
    case sky
    case teal
    case turquoise
    case mint
    case green
    case forest
    case lime
    case olive
    case gold
    case sand
    case bronze
    case amber
    case orange
    case copper
    case rust
    case coral
    case peach
    case brick
    case crimson
    case ruby
    case berry
    case rose
    case magenta
    case orchid
    case indigo
    case navy
    case steel
    case violet
    case iris
    case lavender
    case plum
    case slate
    case smoke
    case charcoal
    case graphite
    case mocha

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .aqua: return "Aqua"
        case .ice: return "Ice"
        case .sky: return "Sky"
        case .teal: return "Teal"
        case .turquoise: return "Turquoise"
        case .mint: return "Mint"
        case .green: return "Green"
        case .forest: return "Forest"
        case .lime: return "Lime"
        case .olive: return "Olive"
        case .gold: return "Gold"
        case .sand: return "Sand"
        case .bronze: return "Bronze"
        case .amber: return "Amber"
        case .orange: return "Orange"
        case .copper: return "Copper"
        case .rust: return "Rust"
        case .coral: return "Coral"
        case .peach: return "Peach"
        case .brick: return "Brick"
        case .crimson: return "Crimson"
        case .ruby: return "Ruby"
        case .berry: return "Berry"
        case .rose: return "Rose"
        case .magenta: return "Magenta"
        case .orchid: return "Orchid"
        case .indigo: return "Indigo"
        case .navy: return "Navy"
        case .steel: return "Steel"
        case .violet: return "Violet"
        case .iris: return "Iris"
        case .lavender: return "Lavender"
        case .plum: return "Plum"
        case .slate: return "Slate"
        case .smoke: return "Smoke"
        case .charcoal: return "Charcoal"
        case .graphite: return "Graphite"
        case .mocha: return "Mocha"
        }
    }
}

// MARK: - SidebarIconPaletteDescriptor

struct SidebarIconPaletteDescriptor {
    let foreground: Color
    let solidBackground: Color
    let gradientStart: Color
    let gradientEnd: Color
    let border: Color
}

// MARK: - SidebarIconPalette + descriptor

extension SidebarIconPalette {
    var descriptor: SidebarIconPaletteDescriptor {
        switch self {
        case .blue:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.55, green: 0.76, blue: 1.0),
                solidBackground: Color(red: 0.09, green: 0.18, blue: 0.31),
                gradientStart: Color(red: 0.14, green: 0.30, blue: 0.58),
                gradientEnd: Color(red: 0.11, green: 0.55, blue: 0.80),
                border: Color(red: 0.30, green: 0.48, blue: 0.72)
            )
        case .cyan:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.78, green: 0.98, blue: 1.0),
                solidBackground: Color(red: 0.06, green: 0.21, blue: 0.28),
                gradientStart: Color(red: 0.06, green: 0.37, blue: 0.50),
                gradientEnd: Color(red: 0.10, green: 0.67, blue: 0.78),
                border: Color(red: 0.24, green: 0.58, blue: 0.67)
            )
        case .aqua:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.84, green: 1.0, blue: 0.98),
                solidBackground: Color(red: 0.05, green: 0.22, blue: 0.24),
                gradientStart: Color(red: 0.05, green: 0.40, blue: 0.41),
                gradientEnd: Color(red: 0.12, green: 0.73, blue: 0.67),
                border: Color(red: 0.24, green: 0.63, blue: 0.58)
            )
        case .ice:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.91, green: 0.98, blue: 1.0),
                solidBackground: Color(red: 0.12, green: 0.18, blue: 0.24),
                gradientStart: Color(red: 0.19, green: 0.30, blue: 0.42),
                gradientEnd: Color(red: 0.37, green: 0.57, blue: 0.72),
                border: Color(red: 0.41, green: 0.57, blue: 0.69)
            )
        case .sky:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.86, green: 0.95, blue: 1.0),
                solidBackground: Color(red: 0.10, green: 0.19, blue: 0.29),
                gradientStart: Color(red: 0.16, green: 0.31, blue: 0.56),
                gradientEnd: Color(red: 0.28, green: 0.56, blue: 0.87),
                border: Color(red: 0.35, green: 0.52, blue: 0.75)
            )
        case .teal:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.73, green: 0.96, blue: 0.95),
                solidBackground: Color(red: 0.07, green: 0.24, blue: 0.24),
                gradientStart: Color(red: 0.07, green: 0.39, blue: 0.42),
                gradientEnd: Color(red: 0.11, green: 0.63, blue: 0.61),
                border: Color(red: 0.26, green: 0.58, blue: 0.55)
            )
        case .turquoise:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.77, green: 0.98, blue: 0.96),
                solidBackground: Color(red: 0.06, green: 0.22, blue: 0.20),
                gradientStart: Color(red: 0.08, green: 0.40, blue: 0.35),
                gradientEnd: Color(red: 0.13, green: 0.71, blue: 0.58),
                border: Color(red: 0.24, green: 0.62, blue: 0.52)
            )
        case .mint:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.83, green: 0.99, blue: 0.91),
                solidBackground: Color(red: 0.08, green: 0.25, blue: 0.18),
                gradientStart: Color(red: 0.11, green: 0.42, blue: 0.28),
                gradientEnd: Color(red: 0.17, green: 0.66, blue: 0.44),
                border: Color(red: 0.30, green: 0.58, blue: 0.41)
            )
        case .green:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.89, green: 0.98, blue: 0.84),
                solidBackground: Color(red: 0.16, green: 0.24, blue: 0.09),
                gradientStart: Color(red: 0.24, green: 0.42, blue: 0.10),
                gradientEnd: Color(red: 0.43, green: 0.66, blue: 0.18),
                border: Color(red: 0.46, green: 0.62, blue: 0.24)
            )
        case .forest:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.88, green: 0.98, blue: 0.85),
                solidBackground: Color(red: 0.10, green: 0.20, blue: 0.09),
                gradientStart: Color(red: 0.15, green: 0.33, blue: 0.10),
                gradientEnd: Color(red: 0.24, green: 0.52, blue: 0.17),
                border: Color(red: 0.31, green: 0.48, blue: 0.22)
            )
        case .lime:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.94, green: 1.0, blue: 0.80),
                solidBackground: Color(red: 0.20, green: 0.24, blue: 0.08),
                gradientStart: Color(red: 0.32, green: 0.43, blue: 0.10),
                gradientEnd: Color(red: 0.56, green: 0.73, blue: 0.17),
                border: Color(red: 0.52, green: 0.64, blue: 0.22)
            )
        case .olive:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.92, green: 0.96, blue: 0.78),
                solidBackground: Color(red: 0.22, green: 0.23, blue: 0.10),
                gradientStart: Color(red: 0.34, green: 0.37, blue: 0.12),
                gradientEnd: Color(red: 0.50, green: 0.57, blue: 0.20),
                border: Color(red: 0.49, green: 0.54, blue: 0.23)
            )
        case .gold:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.95, blue: 0.76),
                solidBackground: Color(red: 0.31, green: 0.24, blue: 0.09),
                gradientStart: Color(red: 0.55, green: 0.37, blue: 0.07),
                gradientEnd: Color(red: 0.85, green: 0.63, blue: 0.15),
                border: Color(red: 0.68, green: 0.50, blue: 0.20)
            )
        case .sand:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.95, blue: 0.86),
                solidBackground: Color(red: 0.27, green: 0.22, blue: 0.14),
                gradientStart: Color(red: 0.45, green: 0.33, blue: 0.18),
                gradientEnd: Color(red: 0.69, green: 0.54, blue: 0.31),
                border: Color(red: 0.60, green: 0.49, blue: 0.31)
            )
        case .bronze:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.91, blue: 0.79),
                solidBackground: Color(red: 0.28, green: 0.17, blue: 0.10),
                gradientStart: Color(red: 0.47, green: 0.24, blue: 0.12),
                gradientEnd: Color(red: 0.72, green: 0.41, blue: 0.21),
                border: Color(red: 0.61, green: 0.36, blue: 0.20)
            )
        case .amber:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.93, blue: 0.76),
                solidBackground: Color(red: 0.34, green: 0.20, blue: 0.06),
                gradientStart: Color(red: 0.62, green: 0.34, blue: 0.05),
                gradientEnd: Color(red: 0.91, green: 0.56, blue: 0.10),
                border: Color(red: 0.76, green: 0.46, blue: 0.16)
            )
        case .orange:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.90, blue: 0.78),
                solidBackground: Color(red: 0.34, green: 0.17, blue: 0.08),
                gradientStart: Color(red: 0.62, green: 0.25, blue: 0.07),
                gradientEnd: Color(red: 0.87, green: 0.46, blue: 0.12),
                border: Color(red: 0.72, green: 0.38, blue: 0.17)
            )
        case .copper:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.88, blue: 0.79),
                solidBackground: Color(red: 0.33, green: 0.15, blue: 0.09),
                gradientStart: Color(red: 0.59, green: 0.23, blue: 0.11),
                gradientEnd: Color(red: 0.80, green: 0.37, blue: 0.19),
                border: Color(red: 0.69, green: 0.31, blue: 0.18)
            )
        case .rust:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.99, green: 0.87, blue: 0.81),
                solidBackground: Color(red: 0.29, green: 0.12, blue: 0.09),
                gradientStart: Color(red: 0.47, green: 0.18, blue: 0.12),
                gradientEnd: Color(red: 0.65, green: 0.25, blue: 0.17),
                border: Color(red: 0.56, green: 0.23, blue: 0.17)
            )
        case .coral:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.86, blue: 0.83),
                solidBackground: Color(red: 0.33, green: 0.12, blue: 0.12),
                gradientStart: Color(red: 0.60, green: 0.18, blue: 0.19),
                gradientEnd: Color(red: 0.84, green: 0.33, blue: 0.29),
                border: Color(red: 0.69, green: 0.29, blue: 0.28)
            )
        case .peach:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.91, blue: 0.84),
                solidBackground: Color(red: 0.31, green: 0.15, blue: 0.12),
                gradientStart: Color(red: 0.55, green: 0.22, blue: 0.17),
                gradientEnd: Color(red: 0.86, green: 0.45, blue: 0.31),
                border: Color(red: 0.71, green: 0.37, blue: 0.28)
            )
        case .brick:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.99, green: 0.87, blue: 0.80),
                solidBackground: Color(red: 0.30, green: 0.11, blue: 0.08),
                gradientStart: Color(red: 0.50, green: 0.16, blue: 0.10),
                gradientEnd: Color(red: 0.73, green: 0.26, blue: 0.16),
                border: Color(red: 0.61, green: 0.24, blue: 0.17)
            )
        case .crimson:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.85, blue: 0.88),
                solidBackground: Color(red: 0.29, green: 0.08, blue: 0.12),
                gradientStart: Color(red: 0.48, green: 0.10, blue: 0.18),
                gradientEnd: Color(red: 0.74, green: 0.16, blue: 0.31),
                border: Color(red: 0.62, green: 0.18, blue: 0.29)
            )
        case .ruby:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.84, blue: 0.87),
                solidBackground: Color(red: 0.30, green: 0.07, blue: 0.10),
                gradientStart: Color(red: 0.53, green: 0.10, blue: 0.16),
                gradientEnd: Color(red: 0.80, green: 0.17, blue: 0.25),
                border: Color(red: 0.67, green: 0.19, blue: 0.25)
            )
        case .berry:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.99, green: 0.86, blue: 0.93),
                solidBackground: Color(red: 0.28, green: 0.09, blue: 0.20),
                gradientStart: Color(red: 0.46, green: 0.12, blue: 0.31),
                gradientEnd: Color(red: 0.67, green: 0.19, blue: 0.47),
                border: Color(red: 0.57, green: 0.21, blue: 0.42)
            )
        case .rose:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 1.0, green: 0.86, blue: 0.92),
                solidBackground: Color(red: 0.29, green: 0.11, blue: 0.18),
                gradientStart: Color(red: 0.50, green: 0.16, blue: 0.30),
                gradientEnd: Color(red: 0.77, green: 0.26, blue: 0.45),
                border: Color(red: 0.62, green: 0.26, blue: 0.40)
            )
        case .magenta:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.97, green: 0.86, blue: 1.0),
                solidBackground: Color(red: 0.22, green: 0.10, blue: 0.27),
                gradientStart: Color(red: 0.40, green: 0.15, blue: 0.53),
                gradientEnd: Color(red: 0.63, green: 0.20, blue: 0.75),
                border: Color(red: 0.52, green: 0.25, blue: 0.68)
            )
        case .orchid:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.98, green: 0.88, blue: 1.0),
                solidBackground: Color(red: 0.23, green: 0.11, blue: 0.31),
                gradientStart: Color(red: 0.39, green: 0.17, blue: 0.52),
                gradientEnd: Color(red: 0.62, green: 0.27, blue: 0.77),
                border: Color(red: 0.54, green: 0.29, blue: 0.67)
            )
        case .indigo:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.88, green: 0.89, blue: 1.0),
                solidBackground: Color(red: 0.14, green: 0.12, blue: 0.31),
                gradientStart: Color(red: 0.23, green: 0.18, blue: 0.57),
                gradientEnd: Color(red: 0.38, green: 0.29, blue: 0.81),
                border: Color(red: 0.40, green: 0.31, blue: 0.73)
            )
        case .navy:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.85, green: 0.89, blue: 1.0),
                solidBackground: Color(red: 0.08, green: 0.11, blue: 0.24),
                gradientStart: Color(red: 0.12, green: 0.17, blue: 0.45),
                gradientEnd: Color(red: 0.20, green: 0.28, blue: 0.68),
                border: Color(red: 0.24, green: 0.31, blue: 0.58)
            )
        case .steel:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.88, green: 0.93, blue: 0.98),
                solidBackground: Color(red: 0.12, green: 0.16, blue: 0.21),
                gradientStart: Color(red: 0.18, green: 0.24, blue: 0.33),
                gradientEnd: Color(red: 0.30, green: 0.39, blue: 0.51),
                border: Color(red: 0.36, green: 0.44, blue: 0.57)
            )
        case .violet:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.95, green: 0.89, blue: 1.0),
                solidBackground: Color(red: 0.21, green: 0.11, blue: 0.33),
                gradientStart: Color(red: 0.36, green: 0.17, blue: 0.59),
                gradientEnd: Color(red: 0.56, green: 0.25, blue: 0.84),
                border: Color(red: 0.50, green: 0.26, blue: 0.72)
            )
        case .iris:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.92, green: 0.90, blue: 1.0),
                solidBackground: Color(red: 0.19, green: 0.13, blue: 0.34),
                gradientStart: Color(red: 0.30, green: 0.20, blue: 0.59),
                gradientEnd: Color(red: 0.47, green: 0.31, blue: 0.86),
                border: Color(red: 0.46, green: 0.33, blue: 0.73)
            )
        case .lavender:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.97, green: 0.92, blue: 1.0),
                solidBackground: Color(red: 0.25, green: 0.18, blue: 0.35),
                gradientStart: Color(red: 0.41, green: 0.28, blue: 0.58),
                gradientEnd: Color(red: 0.63, green: 0.48, blue: 0.82),
                border: Color(red: 0.57, green: 0.45, blue: 0.72)
            )
        case .plum:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.97, green: 0.88, blue: 0.98),
                solidBackground: Color(red: 0.25, green: 0.10, blue: 0.25),
                gradientStart: Color(red: 0.41, green: 0.14, blue: 0.44),
                gradientEnd: Color(red: 0.61, green: 0.22, blue: 0.60),
                border: Color(red: 0.54, green: 0.24, blue: 0.53)
            )
        case .slate:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.88, green: 0.91, blue: 0.96),
                solidBackground: Color(red: 0.14, green: 0.17, blue: 0.23),
                gradientStart: Color(red: 0.22, green: 0.26, blue: 0.36),
                gradientEnd: Color(red: 0.31, green: 0.37, blue: 0.47),
                border: Color(red: 0.36, green: 0.42, blue: 0.54)
            )
        case .smoke:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.92, green: 0.94, blue: 0.97),
                solidBackground: Color(red: 0.18, green: 0.19, blue: 0.22),
                gradientStart: Color(red: 0.27, green: 0.29, blue: 0.33),
                gradientEnd: Color(red: 0.41, green: 0.43, blue: 0.49),
                border: Color(red: 0.45, green: 0.47, blue: 0.53)
            )
        case .charcoal:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.93, green: 0.93, blue: 0.95),
                solidBackground: Color(red: 0.08, green: 0.09, blue: 0.11),
                gradientStart: Color(red: 0.12, green: 0.14, blue: 0.17),
                gradientEnd: Color(red: 0.20, green: 0.22, blue: 0.26),
                border: Color(red: 0.27, green: 0.29, blue: 0.34)
            )
        case .graphite:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.92, green: 0.93, blue: 0.95),
                solidBackground: Color(red: 0.10, green: 0.11, blue: 0.14),
                gradientStart: Color(red: 0.16, green: 0.18, blue: 0.22),
                gradientEnd: Color(red: 0.28, green: 0.30, blue: 0.35),
                border: Color(red: 0.34, green: 0.36, blue: 0.41)
            )
        case .mocha:
            return SidebarIconPaletteDescriptor(
                foreground: Color(red: 0.96, green: 0.91, blue: 0.87),
                solidBackground: Color(red: 0.19, green: 0.13, blue: 0.11),
                gradientStart: Color(red: 0.31, green: 0.20, blue: 0.16),
                gradientEnd: Color(red: 0.46, green: 0.31, blue: 0.24),
                border: Color(red: 0.47, green: 0.33, blue: 0.28)
            )
        }
    }
}

// MARK: - SidebarItemIcon

struct SidebarItemIcon: Codable, Hashable {
    var symbolName: String
    var palette: SidebarIconPalette
    var fillStyle: SidebarIconFillStyle

    init(
        symbolName: String,
        palette: SidebarIconPalette,
        fillStyle: SidebarIconFillStyle = .gradient
    ) {
        self.symbolName = symbolName.nilIfEmpty ?? "square.grid.2x2.fill"
        self.palette = palette
        self.fillStyle = fillStyle
    }
}

// MARK: - SidebarItemIcon + Defaults

extension SidebarItemIcon {
    static let repositoryDefault = SidebarItemIcon(
        symbolName: "arrow.triangle.branch",
        palette: .blue,
        fillStyle: .gradient
    )

    static let localTerminalDefault = SidebarItemIcon(
        symbolName: "terminal.fill",
        palette: .teal,
        fillStyle: .solid
    )

    static let remoteDefault = SidebarItemIcon(
        symbolName: "globe",
        palette: .orange,
        fillStyle: .gradient
    )

    static let worktreeDefault = SidebarItemIcon(
        symbolName: "circle.fill",
        palette: .mint,
        fillStyle: .solid
    )
}
