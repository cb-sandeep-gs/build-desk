import Foundation

/// How an app is started after it is installed: its command-line arguments, environment
/// variables and a link to open.
public struct LaunchOptions: Sendable, Equatable, Codable {
    public var arguments: [String]
    public var environment: [String: String]
    /// A link handed to the app at launch, to land on a particular screen.
    public var url: String?

    public init(arguments: [String] = [], environment: [String: String] = [:], url: String? = nil) {
        self.arguments = arguments
        self.environment = environment
        self.url = url
    }

    public var isEmpty: Bool { arguments.isEmpty && environment.isEmpty && (url ?? "").isEmpty }

    /// A problem in text a person typed, in words for them.
    public struct ParseError: Error, Equatable, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// Builds options from the three text fields of the window. Arguments and variables are
    /// separated by spaces; quotes keep a value with spaces together.
    public static func parse(arguments: String, environment: String, url: String) throws -> LaunchOptions {
        var variables: [String: String] = [:]
        for entry in try words(in: environment) {
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
                throw ParseError(message: "\"\(entry)\" is not a variable. Write each one as NAME=value.")
            }
            variables[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        let link = url.trimmingCharacters(in: .whitespaces)
        guard link.isEmpty || URL(string: link)?.scheme != nil else {
            throw ParseError(message: "\"\(link)\" is not a link. It needs a scheme, as in myapp://home or https://example.com.")
        }
        return LaunchOptions(arguments: try words(in: arguments), environment: variables, url: link.isEmpty ? nil : link)
    }

    /// Splits text on spaces, as a shell does: single or double quotes keep spaces, and a
    /// backslash keeps the next character.
    static func words(in text: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var isInWord = false
        var quote: Character?
        var isEscaped = false
        for character in text {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
                isInWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                isInWord = true
            } else if character.isWhitespace {
                if isInWord { words.append(current) }
                current = ""
                isInWord = false
            } else {
                current.append(character)
                isInWord = true
            }
        }
        guard quote == nil else { throw ParseError(message: "A quote is opened but never closed.") }
        if isInWord { words.append(current) }
        return words
    }

    /// The arguments as text that `parse` reads back to the same list.
    public var argumentsText: String { arguments.map(Self.quoted).joined(separator: " ") }

    /// The variables as text that `parse` reads back to the same dictionary, in name order.
    public var environmentText: String {
        environment.sorted { $0.key < $1.key }.map { Self.quoted("\($0.key)=\($0.value)") }.joined(separator: " ")
    }

    private static func quoted(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) else { return word }
        return "\"" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
