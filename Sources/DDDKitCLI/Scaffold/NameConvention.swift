import Foundation

/// Splits arbitrary user input ("order-context", "order_context", "OrderContext",
/// "order context") into words, so it can be re-rendered as a valid Swift
/// PascalCase / camelCase identifier.
enum NameConvention {
    static func words(from input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false

        for scalar in input.unicodeScalars {
            let character = Character(scalar)
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                previousWasLower = false
                continue
            }

            if character.isUppercase && previousWasLower {
                words.append(current)
                current = ""
            }

            current.append(character)
            previousWasLower = character.isLowercase
        }

        if !current.isEmpty {
            words.append(current)
        }

        return words
    }

    private static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    static func pascalCase(words: [String]) -> String {
        words.map(capitalized).joined()
    }

    static func pascalCase(from input: String) -> String {
        pascalCase(words: words(from: input))
    }

    static func camelCase(words: [String]) -> String {
        let pascal = pascalCase(words: words)
        guard let first = pascal.first else { return pascal }
        return first.lowercased() + pascal.dropFirst()
    }

    static func camelCase(from input: String) -> String {
        camelCase(words: words(from: input))
    }

    /// Derives a default aggregate name from a project/context name by
    /// stripping a trailing "Context" word, e.g. "OrderContext" -> "Order".
    static func defaultAggregateWords(fromProjectWords words: [String]) -> [String] {
        guard words.count > 1, let last = words.last, last.lowercased() == "context" else {
            return words
        }
        return Array(words.dropLast())
    }
}
