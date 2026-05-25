import Foundation

enum PreviewColorSchemeMode: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

struct BookPreviewTheme: Equatable {
    var lightScheme: String = "default"
    var darkScheme: String = "slate"
    var primary: String = "indigo"
    var accent: String = "indigo"
}

struct BookPreviewStyleBundle: Equatable {
    var stylesheets: [BookStylesheet]
    var theme: BookPreviewTheme?
    var generatedThemeCSS: String
    var usesGeneratedTheme: Bool
}

struct BookStylesheet: Equatable {
    var href: String
    var media: String?
}

enum BookloopThemeCSSGenerator {
    static func generate(theme: BookPreviewTheme) -> String {
        let primary = sanitizeColorName(theme.primary)
        let accent = sanitizeColorName(theme.accent)
        let lightScheme = sanitizeSchemeName(theme.lightScheme, fallback: "default")
        let darkScheme = sanitizeSchemeName(theme.darkScheme, fallback: "slate")

        return """
        :root { --md-hue: 232; }
        \(schemeCSS(name: lightScheme, dark: false))
        \(schemeCSS(name: darkScheme, dark: true))
        \(primaryCSS(name: primary))
        \(accentCSS(name: accent))
        body.bookloop-preview.has-book-theme {
          color: var(--md-default-fg-color);
          background: var(--md-default-bg-color);
        }
        """
    }

    private static func sanitizeColorName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "indigo" : trimmed
    }

    private static func sanitizeSchemeName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func schemeCSS(name: String, dark: Bool) -> String {
        if dark || name == "slate" || name == "dark" {
            return """
            [data-md-color-scheme="\(name)"] {
              color-scheme: dark;
              --md-default-fg-color: hsla(var(--md-hue), 15%, 90%, 0.82);
              --md-default-fg-color--light: hsla(var(--md-hue), 15%, 90%, 0.56);
              --md-default-bg-color: hsla(var(--md-hue), 15%, 14%, 1);
              --md-default-bg-color--light: hsla(var(--md-hue), 15%, 14%, 0.54);
              --md-code-fg-color: hsla(var(--md-hue), 18%, 86%, 0.82);
              --md-code-bg-color: hsla(var(--md-hue), 15%, 18%, 1);
              --md-typeset-color: var(--md-default-fg-color);
              --md-typeset-a-color: var(--md-primary-fg-color);
              --md-admonition-bg-color: var(--md-default-bg-color);
              --md-admonition-fg-color: var(--md-default-fg-color);
            }
            """
        }

        return """
        [data-md-color-scheme="\(name)"] {
          color-scheme: light;
          --md-default-fg-color: hsla(var(--md-hue), 75%, 10%, 0.87);
          --md-default-fg-color--light: hsla(var(--md-hue), 75%, 10%, 0.54);
          --md-default-bg-color: hsla(0, 0%, 100%, 1);
          --md-default-bg-color--light: hsla(0, 0%, 100%, 0.7);
          --md-code-fg-color: hsla(var(--md-hue), 18%, 13%, 0.87);
          --md-code-bg-color: hsla(var(--md-hue), 15%, 95%, 1);
          --md-typeset-color: var(--md-default-fg-color);
          --md-typeset-a-color: var(--md-primary-fg-color);
          --md-admonition-bg-color: var(--md-default-bg-color);
          --md-admonition-fg-color: var(--md-default-fg-color);
        }
        """
    }

    private static func primaryCSS(name: String) -> String {
        if let block = primaryColorBlocks[name] {
            return block
        }
        return primaryColorBlocks["indigo"] ?? ""
    }

    private static func accentCSS(name: String) -> String {
        if let block = accentColorBlocks[name] {
            return block
        }
        return accentColorBlocks["indigo"] ?? ""
    }

    private static let primaryColorBlocks: [String: String] = [
        "indigo": """
        [data-md-color-primary="indigo"] {
          --md-primary-fg-color: #4051b5;
          --md-primary-fg-color--light: #5d6cc0;
          --md-primary-fg-color--dark: #303fa1;
          --md-primary-bg-color: #fff;
          --md-primary-bg-color--light: #ffffffb3;
          --md-typeset-a-color: var(--md-primary-fg-color);
        }
        [data-md-color-scheme="slate"][data-md-color-primary="indigo"] {
          --md-typeset-a-color: #5488e8;
        }
        """,
        "blue": """
        [data-md-color-primary="blue"] {
          --md-primary-fg-color: #2094f3;
          --md-primary-fg-color--light: #42a5f5;
          --md-primary-fg-color--dark: #1975d2;
          --md-primary-bg-color: #fff;
          --md-primary-bg-color--light: #ffffffb3;
          --md-typeset-a-color: var(--md-primary-fg-color);
        }
        """,
        "teal": """
        [data-md-color-primary="teal"] {
          --md-primary-fg-color: #009485;
          --md-primary-fg-color--light: #26a699;
          --md-primary-fg-color--dark: #007a6c;
          --md-primary-bg-color: #fff;
          --md-primary-bg-color--light: #ffffffb3;
          --md-typeset-a-color: var(--md-primary-fg-color);
        }
        """,
        "green": """
        [data-md-color-primary="green"] {
          --md-primary-fg-color: #4cae4f;
          --md-primary-fg-color--light: #68bb6c;
          --md-primary-fg-color--dark: #398e3d;
          --md-primary-bg-color: #fff;
          --md-primary-bg-color--light: #ffffffb3;
          --md-typeset-a-color: var(--md-primary-fg-color);
        }
        """,
        "purple": """
        [data-md-color-primary="purple"] {
          --md-primary-fg-color: #ab47bd;
          --md-primary-fg-color--light: #bb69c9;
          --md-primary-fg-color--dark: #8c24a8;
          --md-primary-bg-color: #fff;
          --md-primary-bg-color--light: #ffffffb3;
          --md-typeset-a-color: var(--md-primary-fg-color);
        }
        """,
        "deep-purple": """
        [data-md-color-primary="deep-purple"] {
          --md-primary-fg-color: #7e56c2;
          --md-primary-fg-color--light: #9574cd;
          --md-primary-fg-color--dark: #673ab6;
          --md-primary-bg-color: #fff;
          --md-primary-bg-color--light: #ffffffb3;
          --md-typeset-a-color: var(--md-primary-fg-color);
        }
        """,
        "red": """
        [data-md-color-primary="red"] {
          --md-primary-fg-color: #ef5552;
          --md-primary-fg-color--light: #e57171;
          --md-primary-fg-color--dark: #e53734;
          --md-primary-bg-color: #fff;
          --md-primary-bg-color--light: #ffffffb3;
          --md-typeset-a-color: var(--md-primary-fg-color);
        }
        """,
        "orange": """
        [data-md-color-primary="orange"] {
          --md-primary-fg-color: #ffa724;
          --md-primary-fg-color--light: #ffa724;
          --md-primary-fg-color--dark: #fa8900;
          --md-primary-bg-color: #fff;
          --md-primary-bg-color--light: #ffffffb3;
          --md-typeset-a-color: var(--md-primary-fg-color);
        }
        """
    ]

    private static let accentColorBlocks: [String: String] = [
        "indigo": """
        [data-md-color-accent="indigo"] {
          --md-accent-fg-color: #526cfe;
          --md-accent-fg-color--transparent: #526cfe1a;
          --md-accent-bg-color: #fff;
          --md-accent-bg-color--light: #ffffffb3;
        }
        """,
        "blue": """
        [data-md-color-accent="blue"] {
          --md-accent-fg-color: #4287ff;
          --md-accent-fg-color--transparent: #4287ff1a;
          --md-accent-bg-color: #fff;
          --md-accent-bg-color--light: #ffffffb3;
        }
        """,
        "teal": """
        [data-md-color-accent="teal"] {
          --md-accent-fg-color: #00bda4;
          --md-accent-fg-color--transparent: #00bda41a;
          --md-accent-bg-color: #fff;
          --md-accent-bg-color--light: #ffffffb3;
        }
        """,
        "green": """
        [data-md-color-accent="green"] {
          --md-accent-fg-color: #00c753;
          --md-accent-fg-color--transparent: #00c7531a;
          --md-accent-bg-color: #fff;
          --md-accent-bg-color--light: #ffffffb3;
        }
        """,
        "purple": """
        [data-md-color-accent="purple"] {
          --md-accent-fg-color: #df41fb;
          --md-accent-fg-color--transparent: #df41fb1a;
          --md-accent-bg-color: #fff;
          --md-accent-bg-color--light: #ffffffb3;
        }
        """,
        "red": """
        [data-md-color-accent="red"] {
          --md-accent-fg-color: #ff1947;
          --md-accent-fg-color--transparent: #ff19471a;
          --md-accent-bg-color: #fff;
          --md-accent-bg-color--light: #ffffffb3;
        }
        """,
        "orange": """
        [data-md-color-accent="orange"] {
          --md-accent-fg-color: #ff9100;
          --md-accent-fg-color--transparent: #ff91001a;
          --md-accent-bg-color: #fff;
          --md-accent-bg-color--light: #ffffffb3;
        }
        """
    ]
}
