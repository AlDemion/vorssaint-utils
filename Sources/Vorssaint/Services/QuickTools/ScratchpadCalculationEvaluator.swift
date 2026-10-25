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
        let formatted: String?
        let variable: String?
    }

    struct Result: Equatable {
        let lines: [LineResult]
        let variables: [String: Double]

        var copyText: String {
            lines.map { line in
                guard let formatted = line.formatted,
                      formatted.caseInsensitiveCompare(
                        line.source.trimmingCharacters(in: .whitespaces)) != .orderedSame
                else { return line.source }
                return "\(line.source)    \(formatted)"
            }.joined(separator: "\n")
        }
    }

    static func evaluate(_ source: String,
                         currencyRates: ScratchpadCurrencyRates? = nil,
                         decimalSeparator: String = Locale.current.decimalSeparator ?? ".",
                         groupingSeparator: String = Locale.current.groupingSeparator ?? ",",
                         locale: Locale = .current) -> Result {
        var variables: [String: Double] = [:]
        var previous: Double?
        var total = 0.0
        var count = 0
        var results: [LineResult] = []

        for line in lines(in: source) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                results.append(LineResult(source: line, value: nil, formatted: nil, variable: nil))
                continue
            }

            let assignment = assignmentParts(in: trimmed)
            let expression = assignment?.expression ?? trimmed
            let expanded = substitute(expression, variables: variables,
                                       previous: previous, total: total, count: count,
                                       decimalSeparator: decimalSeparator)
            let evaluated = evaluateExpression(expanded,
                                               currencyRates: currencyRates,
                                               decimalSeparator: decimalSeparator,
                                               groupingSeparator: groupingSeparator,
                                               locale: locale)
            let value = evaluated?.value
            let variable = assignment?.name.lowercased()
            if let value, value.isFinite {
                if let variable {
                    variables[variable] = value
                }
                previous = value
                total += value
                count += 1
            } else if let variable {
                variables.removeValue(forKey: variable)
            }
            results.append(LineResult(source: line, value: value, formatted: evaluated?.formatted, variable: variable))
        }

        return Result(lines: results, variables: variables)
    }

    private static func evaluateExpression(_ expression: String,
                                           currencyRates: ScratchpadCurrencyRates?,
                                           decimalSeparator: String,
                                           groupingSeparator: String,
                                           locale: Locale) -> (value: Double, formatted: String)? {
        if let rates = currencyRates,
           let converted = ScratchpadCurrency.convert(expression, rates: rates,
                                                       decimalSeparator: decimalSeparator,
                                                       groupingSeparator: groupingSeparator,
                                                       locale: locale) {
            return (converted.value, converted.formatted)
        }
        if let converted = CommandBarUnits.convert(expression,
                                                   decimalSeparator: decimalSeparator,
                                                   groupingSeparator: groupingSeparator,
                                                   locale: locale) {
            return (converted.value, converted.formatted)
        }
        if let value = CommandBarMath.evaluate(expression,
                                                decimalSeparator: decimalSeparator,
                                                groupingSeparator: groupingSeparator,
                                                locale: locale) {
            return (value.value, value.formatted)
        }
        // CommandBarMath intentionally rejects lone numbers in launcher
        // queries. A calculation line may validly be a literal or variable.
        guard let value = CommandBarMath.literalValue(expression, decimalSeparator: decimalSeparator,
                                                     groupingSeparator: groupingSeparator),
              let formatted = CommandBarMath.format(value, locale: locale) else { return nil }
        return (value, formatted)
    }

    private struct Assignment {
        let name: String
        let expression: String
    }

    private static func assignmentParts(in line: String) -> Assignment? {
        guard let match = assignmentPattern.firstMatch(
            in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges == 2 + 1 else { return nil }
        let value = line as NSString
        let name = value.substring(with: match.range(at: 1))
        let expression = value.substring(with: match.range(at: 2))
        return Assignment(name: name, expression: expression)
    }

    private static let assignmentPattern = try! NSRegularExpression(pattern: #"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$"#)

    private static func substitute(_ expression: String,
                                   variables: [String: Double],
                                   previous: Double?, total: Double, count: Int,
                                   decimalSeparator: String) -> String {
        let special: [String: Double?] = [
            "prev": previous,
            "sum": count == 0 ? nil : total,
            "avg": count == 0 ? nil : total / Double(count),
        ]
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
            let name = word.lowercased()
            if !(start > 0 && (characters[start - 1].isNumber || characters[start - 1] == ".")),
               let value = variables[name] ?? special[name] ?? nil {
                output += localizedNumber(value, decimalSeparator: decimalSeparator)
            } else {
                output += word
            }
        }
        return output
    }

    private static func localizedNumber(_ value: Double, decimalSeparator: String) -> String {
        CommandBarMath.reusableExpression(for: .init(formatted: "", value: value, closingBrackets: ""),
                                          decimalSeparator: decimalSeparator)
    }

    /// Splits on the line separators a note can contain, including the
    /// Windows and classic Mac forms, so a pasted note evaluates the same
    /// number of lines it displays. Callers keep their own source spelling.
    static func lines(in source: String) -> [String] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        return normalized.components(separatedBy: "\n")
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isASCII && character.isLetter
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }
}
