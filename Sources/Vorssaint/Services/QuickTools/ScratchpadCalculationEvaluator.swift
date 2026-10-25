// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Evaluates the numeric subset of Scratchpad calculation mode.
///
/// This layer deliberately has no UI or persistence concerns. It evaluates
/// each line in order, so later lines can refer to earlier answers without
/// changing the text the user wrote.
enum ScratchpadCalculationEvaluator {
    struct LineResult: Equatable {
        let source: String
        let value: Double?
        let variable: String?
    }

    struct Result: Equatable {
        let lines: [LineResult]
        let variables: [String: Double]
    }

    static func evaluate(_ source: String,
                         decimalSeparator: String = Locale.current.decimalSeparator ?? ".",
                         groupingSeparator: String = Locale.current.groupingSeparator ?? ",",
                         locale: Locale = .current) -> Result {
        var variables: [String: Double] = [:]
        var previousValues: [Double] = []
        var results: [LineResult] = []

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                results.append(LineResult(source: line, value: nil, variable: nil))
                continue
            }

            let assignment = assignmentParts(in: trimmed)
            let expression = assignment?.expression ?? trimmed
            let expanded = substitute(expression, variables: variables,
                                       previousValues: previousValues,
                                       decimalSeparator: decimalSeparator)
            let value = evaluateExpression(expanded,
                                           decimalSeparator: decimalSeparator,
                                           groupingSeparator: groupingSeparator,
                                           locale: locale)
            let variable = assignment?.name.lowercased()
            if let value, value.isFinite {
                if let variable {
                    variables[variable] = value
                }
                previousValues.append(value)
            }
            results.append(LineResult(source: line, value: value, variable: variable))
        }

        return Result(lines: results, variables: variables)
    }

    private static func evaluateExpression(_ expression: String,
                                           decimalSeparator: String,
                                           groupingSeparator: String,
                                           locale: Locale) -> Double? {
        if let value = CommandBarMath.evaluate(expression,
                                                decimalSeparator: decimalSeparator,
                                                groupingSeparator: groupingSeparator,
                                                locale: locale)?.value {
            return value
        }
        // CommandBarMath intentionally rejects lone numbers in launcher
        // queries. A calculation line may validly be a literal or variable.
        return CommandBarMath.evaluate(expression + "+0",
                                       decimalSeparator: decimalSeparator,
                                       groupingSeparator: groupingSeparator,
                                       locale: locale)?.value
    }

    private struct Assignment {
        let name: String
        let expression: String
    }

    private static func assignmentParts(in line: String) -> Assignment? {
        let pattern = #"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
            in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges == 2 + 1 else { return nil }
        let value = line as NSString
        let name = value.substring(with: match.range(at: 1))
        let expression = value.substring(with: match.range(at: 2))
        return Assignment(name: name, expression: expression)
    }

    private static func substitute(_ expression: String,
                                   variables: [String: Double],
                                   previousValues: [Double],
                                   decimalSeparator: String) -> String {
        let special: [String: Double?] = [
            "prev": previousValues.last,
            "sum": previousValues.isEmpty ? nil : previousValues.reduce(0, +),
            "avg": previousValues.isEmpty ? nil : previousValues.reduce(0, +) / Double(previousValues.count),
        ]
        let values = variables.merging(special.compactMapValues { $0 }) { current, _ in current }
        let characters = Array(expression)
        var output = ""
        var index = 0
        while index < characters.count {
            guard isIdentifierStart(characters[index]) else {
                output.append(characters[index])
                index += 1
                continue
            }
            let start = index
            index += 1
            while index < characters.count, isIdentifierPart(characters[index]) {
                index += 1
            }
            let word = String(characters[start..<index])
            if let value = values[word.lowercased()] {
                output += localizedNumber(value, decimalSeparator: decimalSeparator)
            } else {
                output += word
            }
        }
        return output
    }

    private static func localizedNumber(_ value: Double, decimalSeparator: String) -> String {
        let raw = String(value)
        let separator = decimalSeparator.isEmpty ? "." : decimalSeparator
        return raw.replacingOccurrences(of: ".", with: separator)
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isASCII && character.isLetter
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }
}
