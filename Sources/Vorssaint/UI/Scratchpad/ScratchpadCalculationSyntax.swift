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
            guard contentsEnd > lineStart else { continue }
            // Each line is matched on its own, so a long note costs one pass over
            // its text rather than one per line.
            spans += lineSpans(in: ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart)),
                               offset: lineStart)
        }
        return spans
    }

    /// The answered-line flags to colour with. While a new answer is on its way
    /// the results are empty; the flags from the last answer then stand in, so
    /// typing does not flash the colours off, but only while the note still has
    /// as many lines as they describe. After a line is added or removed they
    /// would sit on the wrong lines, so none are used until the answer arrives.
    static func flags(current: [Bool], previous: [Bool], lineCount: Int) -> [Bool] {
        if !current.isEmpty { return current }
        return previous.count == lineCount ? previous : []
    }

    private static let assignment = try! NSRegularExpression(pattern: #"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*="#)
    private static let label = try! NSRegularExpression(pattern: #"^\s*([^\s:=\d][^:=]*:)(?=\s+\S)"#)
    private static let keyword = try! NSRegularExpression(pattern: #"\b(?:to|into|of|as|in)\b"#,
                                                          options: .caseInsensitive)
    private static let nextWord = try! NSRegularExpression(pattern: #"^\s+([A-Za-z]+)"#)

    private static func lineSpans(in line: String, offset: Int) -> [Span] {
        let ns = line as NSString
        var spans: [Span] = []
        func add(_ range: NSRange, _ role: Role) {
            spans.append(Span(range: NSRange(location: range.location + offset, length: range.length), role: role))
        }
        var body = NSRange(location: 0, length: ns.length)
        if let match = assignment.firstMatch(in: line, range: body) {
            add(match.range(at: 1), .variable)
            body = NSRange(location: NSMaxRange(match.range), length: ns.length - NSMaxRange(match.range))
        } else if let match = label.firstMatch(in: line, range: body) {
            add(match.range(at: 1), .label)
            body = NSRange(location: NSMaxRange(match.range), length: ns.length - NSMaxRange(match.range))
        }
        for match in keyword.matches(in: line, range: body) {
            if ns.substring(with: match.range).lowercased() == "in" {
                // "in" joins a conversion only when a unit or currency follows it:
                // "total in usd". In "12 in", "5 in + 3 in" and "5 in to cm" it is
                // the inches that the line is about, and only the "to" connects.
                let after = NSRange(location: NSMaxRange(match.range), length: ns.length - NSMaxRange(match.range))
                guard let next = nextWord.firstMatch(in: line, range: after),
                      !["to", "into", "as"].contains(ns.substring(with: next.range(at: 1)).lowercased())
                else { continue }
            }
            add(match.range, .keyword)
        }
        return spans
    }
}
