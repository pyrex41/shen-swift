import Foundation

/// Parses KLambda source text (S-expressions) into `KLValue` ASTs.
///
/// KLambda lexical rules:
///   - `(` and `)` are structural.
///   - `"` begins a string that runs to the next `"`. There are NO backslash
///     escapes; literal newlines inside strings are kept verbatim.
///   - Whitespace separates tokens.
///   - Every other run of characters is an atom: an integer, a float, the
///     booleans `true`/`false`, or (otherwise) an interned symbol. Tokens such
///     as `{`, `}`, `->`, `<-`, `@p` are ordinary symbols.
struct Reader {
    private let scalars: [Character]
    private var i = 0
    private let intern: (String) -> KLValue

    init(_ text: String, intern: @escaping (String) -> KLValue) {
        self.scalars = Array(text)
        self.intern = intern
    }

    /// Parses every top-level form in the input.
    mutating func readAll() throws -> [KLValue] {
        var forms: [KLValue] = []
        while true {
            skipWhitespace()
            if i >= scalars.count { break }
            forms.append(try readForm())
        }
        return forms
    }

    private mutating func skipWhitespace() {
        while i < scalars.count {
            let c = scalars[i]
            if c == " " || c == "\n" || c == "\t" || c == "\r" {
                i += 1
            } else {
                break
            }
        }
    }

    private mutating func readForm() throws -> KLValue {
        skipWhitespace()
        guard i < scalars.count else { throw KLError("unexpected end of input") }
        let c = scalars[i]
        switch c {
        case "(":
            return try readList()
        case ")":
            throw KLError("unexpected )")
        case "\"":
            return readString()
        default:
            return readAtom()
        }
    }

    private mutating func readList() throws -> KLValue {
        i += 1 // consume '('
        var elems: [KLValue] = []
        while true {
            skipWhitespace()
            guard i < scalars.count else { throw KLError("unterminated list") }
            if scalars[i] == ")" {
                i += 1
                return KLValue.list(elems)
            }
            elems.append(try readForm())
        }
    }

    private mutating func readString() -> KLValue {
        i += 1 // consume opening quote
        var chars: [Character] = []
        while i < scalars.count && scalars[i] != "\"" {
            chars.append(scalars[i])
            i += 1
        }
        if i < scalars.count { i += 1 } // consume closing quote
        return .str(String(chars))
    }

    private mutating func readAtom() -> KLValue {
        var chars: [Character] = []
        while i < scalars.count {
            let c = scalars[i]
            if c == " " || c == "\n" || c == "\t" || c == "\r"
                || c == "(" || c == ")" || c == "\"" {
                break
            }
            chars.append(c)
            i += 1
        }
        let token = String(chars)
        return Reader.classify(token, intern: intern)
    }

    /// Classifies a bare token as an integer, float, boolean, or symbol.
    static func classify(_ token: String, intern: (String) -> KLValue) -> KLValue {
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        if let n = parseInt(token) { return .int(n) }
        if let d = parseDouble(token) { return .double(d) }
        return intern(token)
    }

    private static func parseInt(_ s: String) -> Int? {
        // Reject a lone sign or empty; require all digits after optional sign.
        guard !s.isEmpty else { return nil }
        var body = Substring(s)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        guard !body.isEmpty, body.allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }
        return Int(s)
    }

    private static func parseDouble(_ s: String) -> Double? {
        // Must contain a digit and a '.' or exponent to count as a float token,
        // so that symbols like "-" or ">" never parse as numbers.
        guard s.contains(where: { $0.isNumber }) else { return nil }
        guard s.contains(".") || s.contains("e") || s.contains("E") else { return nil }
        guard s.first == "-" || s.first == "+" || s.first == "." || (s.first?.isNumber ?? false) else { return nil }
        return Double(s)
    }
}
