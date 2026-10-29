// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Which words of a calculation line read as a name, a label or a connecting
/// word, so the editor can colour them. Only lines that produced an answer are
/// looked at, so a sentence in a note that happens to contain "to" or "in" is
/// left alone. Pure: it returns ranges and never touches the text.
enum ScratchpadCalculationSyntax {
    enum Role: Equatable {
        /// The left side of `rent = 900 eur`.
        case variable
        /// The prefix of `per person: 90 / 3`.
        case label
        /// `to`, `in`, `of`, `as`: the words that connect a conversion or a percentage.
        case keyword
    }

    struct Span: Equatable {
        let range: NSRange
        let role: Role
    }

    /// `answered` says whether the display line at that index produced an
    /// answer; indexes are those of `ScratchpadEditorLayout.lineStartLocations`.
    static func spans(in source: String, answered: (Int) -> Bool) -> [Span] {
        let ns = source as NSString
        var spans: [Span] = []
        for (index, start) in ScratchpadEditorLayout.lineStartLocations(in: source).enumerated()
        where start < ns.length && answered(index) {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: start, length: 0))
            spans += lineSpans(in: ns, line: NSRange(location: lineStart, length: contentsEnd - lineStart))
        }
        return spans
    }

    private static let assignment = try! NSRegularExpression(pattern: #"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*="#)
    private static let label = try! NSRegularExpression(pattern: #"^\s*([^\s:=\d][^:=]*:)(?=\s+\S)"#)
    private static let keyword = try! NSRegularExpression(pattern: #"\b(?:to|into|of|as|in)\b"#,
                                                          options: .caseInsensitive)
    private static let nextWord = try! NSRegularExpression(pattern: #"^\s+([A-Za-z]+)"#)

    private static func lineSpans(in ns: NSString, line: NSRange) -> [Span] {
        guard line.length > 0 else { return [] }
        var spans: [Span] = []
        var body = line
        if let match = assignment.firstMatch(in: ns as String, range: line) {
            spans.append(Span(range: match.range(at: 1), role: .variable))
            body = NSRange(location: NSMaxRange(match.range), length: NSMaxRange(line) - NSMaxRange(match.range))
        } else if let match = label.firstMatch(in: ns as String, range: line) {
            spans.append(Span(range: match.range(at: 1), role: .label))
            body = NSRange(location: NSMaxRange(match.range), length: NSMaxRange(line) - NSMaxRange(match.range))
        }
        for match in keyword.matches(in: ns as String, range: body) {
            let word = ns.substring(with: match.range).lowercased()
            // "5 in to cm": the first "in" is inches and only the "to" connects.
            if word == "in" {
                let after = NSRange(location: NSMaxRange(match.range), length: NSMaxRange(body) - NSMaxRange(match.range))
                if let next = nextWord.firstMatch(in: ns as String, range: after),
                   ["to", "into", "as"].contains(ns.substring(with: next.range(at: 1)).lowercased()) { continue }
            }
            spans.append(Span(range: match.range, role: .keyword))
        }
        return spans
    }
}
