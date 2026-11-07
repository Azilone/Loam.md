import AppKit

/// TeX math as the page draws it without a TeX engine: letters in italic, symbols and Greek letters as their
/// characters, `^` and `_` raised and lowered, `\frac{a}{b}` as `a/b`, `\sqrt{x}` as `√x`. Enough to read a formula
/// written in a note; the Markdown keeps the TeX.
enum MathText {
    static func attributed(_ tex: String, font: NSFont, color: NSColor) -> NSAttributedString {
        var parser = Parser(characters: Array(tex), font: font, color: color)
        return parser.expression(until: nil, rise: 0, scale: 1)
    }

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ",
        "Omega": "Ω", "infty": "∞", "int": "∫", "iint": "∬", "oint": "∮", "sum": "∑", "prod": "∏", "partial": "∂",
        "nabla": "∇", "pm": "±", "mp": "∓", "times": "×", "cdot": "·", "div": "÷", "leq": "≤", "le": "≤", "geq": "≥",
        "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝", "to": "→",
        "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
        "Leftrightarrow": "⇔", "mapsto": "↦", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
        "cup": "∪", "cap": "∩", "emptyset": "∅", "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨",
        "ldots": "…", "cdots": "⋯", "dots": "…", "circ": "∘", "degree": "°", "prime": "′", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "{": "{", "}": "}", "$": "$", "%": "%", "&": "&", "_": "_", "#": "#", "|": "‖",
        ",": "\u{2009}", ";": "\u{2005}", ":": "\u{2005}", "!": "", " ": " ", "quad": "\u{2003}", "qquad": "\u{2003}\u{2003}",
    ]

    /// Commands written as their name, upright: `\sin x`.
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "log", "ln", "lg",
        "exp", "lim", "max", "min", "sup", "inf", "det", "dim", "ker", "gcd", "deg", "arg", "Pr",
    ]

    private struct Parser {
        let characters: [Character]
        let font: NSFont
        let color: NSColor
        var index = 0

        init(characters: [Character], font: NSFont, color: NSColor) {
            self.characters = characters
            self.font = font
            self.color = color
        }

        var upright: NSFont { NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask) }

        func run(_ text: String, italic: Bool, rise: CGFloat, scale: CGFloat) -> NSAttributedString {
            let base = italic ? font : upright
            let sized = NSFontManager.shared.convert(base, toSize: font.pointSize * scale)
            return NSAttributedString(string: text, attributes: [.font: sized, .foregroundColor: color, .baselineOffset: rise])
        }

        /// What follows up to `end` (`}`), or to the end of the formula.
        mutating func expression(until end: Character?, rise: CGFloat, scale: CGFloat) -> NSAttributedString {
            let result = NSMutableAttributedString()
            while index < characters.count {
                let character = characters[index]
                if character == end { index += 1; break }
                result.append(atom(rise: rise, scale: scale))
            }
            return result
        }

        /// One piece: a letter, a group, a command, with its `^` and `_` after it.
        mutating func atom(rise: CGFloat, scale: CGFloat) -> NSAttributedString {
            let character = characters[index]
            let piece = NSMutableAttributedString()
            switch character {
            case "{":
                index += 1
                piece.append(expression(until: "}", rise: rise, scale: scale))
            case "\\":
                piece.append(command(rise: rise, scale: scale))
            case "^", "_":
                // A script with nothing before it.
                break
            case "\n", "\t":
                index += 1
                piece.append(run(" ", italic: false, rise: rise, scale: scale))
            case "&":
                index += 1
            default:
                index += 1
                let italic = character.isLetter
                let spaced = "=+<>".contains(character) ? "\u{2009}\(character)\u{2009}" : (character == "-" ? "\u{2009}−\u{2009}" : String(character))
                piece.append(run(spaced, italic: italic, rise: rise, scale: scale))
            }
            while index < characters.count, characters[index] == "^" || characters[index] == "_" {
                let up = characters[index] == "^"
                index += 1
                let size = font.pointSize * scale
                piece.append(argument(rise: rise + (up ? size * 0.4 : -size * 0.22), scale: scale * 0.72))
            }
            return piece
        }

        /// The argument of a command or a script: a group, or one character or command.
        mutating func argument(rise: CGFloat, scale: CGFloat) -> NSAttributedString {
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count else { return NSAttributedString() }
            if characters[index] == "{" {
                index += 1
                return expression(until: "}", rise: rise, scale: scale)
            }
            if characters[index] == "\\" { return command(rise: rise, scale: scale) }
            let character = characters[index]
            index += 1
            return run(String(character), italic: character.isLetter, rise: rise, scale: scale)
        }

        mutating func command(rise: CGFloat, scale: CGFloat) -> NSAttributedString {
            index += 1
            guard index < characters.count else { return NSAttributedString() }
            var name = ""
            if characters[index].isLetter {
                while index < characters.count, characters[index].isLetter { name.append(characters[index]); index += 1 }
            } else {
                name = String(characters[index])
                index += 1
            }
            switch name {
            case "frac", "dfrac", "tfrac":
                let top = argument(rise: rise, scale: scale)
                let bottom = argument(rise: rise, scale: scale)
                let result = NSMutableAttributedString()
                result.append(wrapped(top, rise: rise, scale: scale))
                result.append(run("/", italic: false, rise: rise, scale: scale))
                result.append(wrapped(bottom, rise: rise, scale: scale))
                return result
            case "sqrt":
                let result = NSMutableAttributedString(attributedString: run("√", italic: false, rise: rise, scale: scale))
                result.append(wrapped(argument(rise: rise, scale: scale), rise: rise, scale: scale))
                return result
            case "text", "mathrm", "textrm", "operatorname", "mathbf", "textbf":
                let inner = argument(rise: rise, scale: scale)
                let upright = NSMutableAttributedString(string: inner.string, attributes: [
                    .font: NSFontManager.shared.convert(self.upright, toSize: font.pointSize * scale), .foregroundColor: color,
                    .baselineOffset: rise,
                ])
                return upright
            case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "limits", "nolimits", "mathit", "mathcal",
                 "mathbb", "boldsymbol":
                return NSAttributedString()
            default:
                if let symbol = MathText.symbols[name] { return run(symbol, italic: false, rise: rise, scale: scale) }
                if MathText.functions.contains(name) { return run(name + "\u{2009}", italic: false, rise: rise, scale: scale) }
                return run(name, italic: false, rise: rise, scale: scale)
            }
        }

        /// `text` in parentheses when it is more than one character, as `a/b` reads `(a+b)/c`.
        func wrapped(_ text: NSAttributedString, rise: CGFloat, scale: CGFloat) -> NSAttributedString {
            guard text.string.trimmingCharacters(in: .whitespaces).count > 1 else { return text }
            let result = NSMutableAttributedString(attributedString: run("(", italic: false, rise: rise, scale: scale))
            result.append(text)
            result.append(run(")", italic: false, rise: rise, scale: scale))
            return result
        }
    }
}
