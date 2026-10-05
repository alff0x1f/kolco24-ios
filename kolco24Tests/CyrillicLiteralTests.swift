//
//  CyrillicLiteralTests.swift
//  kolco24Tests
//
//  Греп-инвариант локализации: в исходниках приложения нет строковых литералов с кириллицей —
//  весь видимый текст идёт через `Localizable.xcstrings`. Исходники читаются с диска хоста по
//  `#filePath` (симулятор видит файловую систему Mac). Пропускаются комментарии, строки логов
//  (`log.debug(…)` и т. п.) и блоки `#if DEBUG … #endif` (превью и их данные).
//

import Foundation
import Testing

struct CyrillicLiteralTests {

    private static let appDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("kolco24")

    @Test func noCyrillicStringLiterals() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.appDir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "исходники не найдены в \(Self.appDir.path)")

        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in Self.checkedLines(lines) where Self.hasCyrillicLiteral(line) {
                hits.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(hits.isEmpty, "кириллица в литералах — вынесите в Localizable.xcstrings:\n\(hits.joined(separator: "\n"))")
    }

    @Test func detectorSelfCheck() {
        #expect(Self.hasCyrillicLiteral(#"Text("Привет")"#))
        #expect(Self.hasCyrillicLiteral(#"let s = "a" + "б""#))
        #expect(!Self.hasCyrillicLiteral(#"Text(.marksTitle) // «Отметки»"#))
        #expect(!Self.hasCyrillicLiteral(#"let url = "https://x.ru" // комментарий"#))
        #expect(!Self.hasCyrillicLiteral(#"Self.log.debug("старт конфетти")"#))
        let lines = ["a", "#if DEBUG", "\"б\"", "#if os(iOS)", "\"в\"", "#endif", "#endif", "\"г\""]
        #expect(Self.checkedLines(lines).map(\.offset) == [0, 7])
    }

    /// Строки вне `#if DEBUG … #endif` (с учётом вложенных `#if`).
    private static func checkedLines(_ lines: [String]) -> [(offset: Int, element: String)] {
        var depth = 0
        var result: [(offset: Int, element: String)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth > 0 {
                if trimmed.hasPrefix("#if") { depth += 1 }
                if trimmed.hasPrefix("#endif") { depth -= 1 }
                continue
            }
            if trimmed.hasPrefix("#if DEBUG") { depth = 1; continue }
            result.append((index, line))
        }
        return result
    }

    /// Есть ли на строке литерал с кириллицей — вне комментария и не в вызове логгера.
    private static func hasCyrillicLiteral(_ line: String) -> Bool {
        if line.range(of: #"\blog\.(debug|info|notice|warning|error|fault|trace)\("#, options: .regularExpression) != nil {
            return false
        }
        var inString = false
        var escaped = false
        var previous: Character?
        for char in line {
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
                else if char.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return true }
            } else {
                if char == "/" && previous == "/" { return false }
                if char == "\"" { inString = true }
            }
            previous = char
        }
        return false
    }
}
