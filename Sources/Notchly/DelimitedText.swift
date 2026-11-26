import Foundation

/// Converts UTF-8 CSV and TSV while preserving quoted separators, quotes and line breaks.
enum DelimitedText {
    enum ParseError: LocalizedError {
        case malformed
        var errorDescription: String? { "The file contains malformed quoted fields." }
    }

    static func convert(_ text: String, from input: Character, to output: Character) throws -> String {
        var result = ""
        var field = ""
        var quoted = false
        var closedQuote = false
        var atFieldStart = true
        var index = text.startIndex
        func emitField() {
            if field.contains(output) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                result += "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            } else { result += field }
            field = ""
            atFieldStart = true
            closedQuote = false
        }
        while index < text.endIndex {
            let c = text[index]
            let next = text.index(after: index)
            if quoted {
                if c == "\"" {
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else { field.append(c) }
            } else if c == input {
                emitField()
                result.append(output)
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                emitField()
                result.append("\n")
                if c == "\r" && next < text.endIndex && text[next] == "\n" {
                    index = text.index(after: next)
                    continue
                }
            } else if c == "\"" && atFieldStart {
                quoted = true
                atFieldStart = false
            } else {
                guard !closedQuote && c != "\"" else { throw ParseError.malformed }
                field.append(c)
                atFieldStart = false
            }
            index = next
        }
        guard !quoted else { throw ParseError.malformed }
        if !atFieldStart || closedQuote || text.last == input { emitField() }
        return result
    }
}
