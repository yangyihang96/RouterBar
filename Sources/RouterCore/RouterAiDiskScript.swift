import Foundation
import JavaScriptCore

/// The script elements of a page as a browser's HTML tokenizer finds them, and whether a script's text parses. Used where
/// the router writes data into a page's script raw (AiDisk's folder names, web.c:28474), so what a browser runs has to be
/// worked out from the page as it arrives rather than from the template.
enum AiDiskScript {
    /// The text of the script element that holds the first `marker`, or nil when no script element holds it or that
    /// element does not end before the page does (a browser then never runs it).
    static func element(containing marker: String, in page: String) -> String? {
        guard let found = page.range(of: marker) else { return nil }
        let units = Array(page.utf16), at = page.utf16.distance(from: page.utf16.startIndex, to: found.lowerBound.samePosition(in: page.utf16) ?? page.utf16.endIndex)
        for script in scripts(units) where at >= script.start {
            guard let end = script.end else { return nil }
            if at < end { return String(decoding: units[script.start..<end], as: UTF16.self) }
        }
        return nil
    }

    /// Where each script element's text starts and ends (nil: it runs to the end of the page), reading the page from its
    /// start as the tokenizer does in the data state (HTML 13.2.5): comments ("<!--" to "-->" or "--!>", "<!-->" and
    /// "<!--->" at once), "<!…>", "<?…>" and "</" not followed by a letter as bogus comments to ">", tags to their ">" (with
    /// quoted attribute values), the RCDATA of title and textarea and the RAWTEXT of style, xmp, iframe, noembed, noframes
    /// and noscript (scripting on) to their end tags, script data to its end tag (`end`), and plaintext to the end.
    static func scripts(_ units: [UInt16]) -> [(start: Int, end: Int?)] {
        func isLetter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }
        func lower(_ unit: UInt16) -> UInt16 { (65...90).contains(unit) ? unit + 32 : unit }
        func starts(_ text: String, at index: Int) -> Bool {
            let mark = Array(text.utf16)
            return index + mark.count <= units.count && Array(units[index..<index + mark.count]) == mark
        }
        func find(_ text: String, from index: Int) -> Int? {
            var at = index
            while at < units.count { if starts(text, at: at) { return at }; at += 1 }
            return nil
        }
        // A tag name from `index`: up to white space, "/" or ">", lowercased.
        func name(at index: Int) -> (name: [UInt16], end: Int) {
            var end = index
            while end < units.count, ![9, 10, 12, 13, 32, 47, 62].contains(units[end]) { end += 1 }
            return (units[index..<end].map(lower), end)
        }
        // The appropriate end tag "</name" followed by white space, "/" or ">", from `index` on.
        func endTag(_ tag: [UInt16], from index: Int) -> Int? {
            var at = index
            while at + 1 < units.count {
                if units[at] == 60, units[at + 1] == 47, at + 2 + tag.count < units.count,
                   units[(at + 2)..<(at + 2 + tag.count)].map(lower) == tag, [9, 10, 12, 13, 32, 47, 62].contains(units[at + 2 + tag.count]) {
                    return at
                }
                at += 1
            }
            return nil
        }
        let rcdata: Set<[UInt16]> = Set(["title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "noscript"].map { Array($0.utf16) })
        var found: [(start: Int, end: Int?)] = []
        var index = 0
        while index < units.count {
            guard units[index] == 60, index + 1 < units.count else { index += 1; continue }
            let next = units[index + 1]
            if starts("<!--", at: index) {
                if starts("<!-->", at: index) { index += 5; continue }
                if starts("<!--->", at: index) { index += 6; continue }
                var at = index + 4, closed = false
                while at < units.count {
                    if starts("-->", at: at) { index = at + 3; closed = true; break }
                    if starts("--!>", at: at) { index = at + 4; closed = true; break }
                    at += 1
                }
                if !closed { return found }
                continue
            }
            if next == 33 || next == 63 || (next == 47 && !(index + 2 < units.count && isLetter(units[index + 2]))) {
                if next == 47, index + 2 < units.count, units[index + 2] == 62 { index += 3; continue }
                guard let close = find(">", from: index + 2) else { return found }
                index = close + 1; continue
            }
            if next == 47 {
                let tag = name(at: index + 2)
                guard let close = tagClose(units, from: tag.end) else { return found }
                index = close + 1; continue
            }
            guard isLetter(next) else { index += 1; continue }
            let tag = name(at: index + 1)
            guard let close = tagClose(units, from: tag.end) else { return found }
            index = close + 1
            if tag.name == Array("script".utf16) {
                guard let end = end(units, from: index) else { found.append((index, nil)); return found }
                found.append((index, end))
                guard let after = tagClose(units, from: end + 8) else { return found }
                index = after + 1
            } else if tag.name == Array("plaintext".utf16) {
                return found
            } else if rcdata.contains(tag.name) {
                guard let end = endTag(tag.name, from: index), let after = tagClose(units, from: end + 2 + tag.name.count) else { return found }
                index = after + 1
            }
        }
        return found
    }

    /// The index of the "<" of the end tag that closes script data starting at `start`: the script data state and its
    /// escaped and double-escaped states (HTML 13.2.5.4–13.2.5.27), and only a whole end tag (`tagClose`). nil when the
    /// script data runs to the end of the page.
    static func end(_ units: [UInt16], from start: Int) -> Int? {
        func isLetter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }
        // "script" (any case) at `index`, followed by white space, "/" or ">".
        func script(at index: Int) -> Bool {
            let name = Array("script".utf16)
            guard index + name.count < units.count else { return false }
            for (offset, unit) in name.enumerated() where (isLetter(units[index + offset]) ? units[index + offset] | 0x20 : units[index + offset]) != unit { return false }
            return [9, 10, 12, 13, 32, 47, 62].contains(units[index + name.count])
        }
        func dashes(before index: Int) -> Bool { index >= start + 2 && units[index - 1] == 45 && units[index - 2] == 45 }
        enum State { case data, escaped, doubleEscaped }
        var state = State.data, index = start
        while index < units.count {
            let unit = units[index]
            switch state {
            case .data:
                if unit == 60, index + 1 < units.count {
                    if units[index + 1] == 47, script(at: index + 2) { return tagClose(units, from: index + 8) == nil ? nil : index }
                    if index + 3 < units.count, units[index + 1] == 33, units[index + 2] == 45, units[index + 3] == 45 {
                        state = .escaped; index += 4; continue
                    }
                }
            case .escaped:
                if unit == 62, dashes(before: index) { state = .data }
                else if unit == 60, index + 1 < units.count {
                    if units[index + 1] == 47, script(at: index + 2) { return tagClose(units, from: index + 8) == nil ? nil : index }
                    if script(at: index + 1) { state = .doubleEscaped; index += 7; continue }
                }
            case .doubleEscaped:
                if unit == 62, dashes(before: index) { state = .data }
                else if unit == 60, index + 1 < units.count, units[index + 1] == 47, script(at: index + 2) { state = .escaped; index += 8; continue }
            }
            index += 1
        }
        return nil
    }

    /// The ">" that ends a tag whose name ends just before `start`, through its attributes as the tokenizer reads them
    /// (HTML 13.2.5.32–13.2.5.40: names, values in double or single quotes or unquoted, a self-closing "/"); nil at the end
    /// of the text, where no tag is emitted.
    static func tagClose(_ units: [UInt16], from start: Int) -> Int? {
        func space(_ unit: UInt16) -> Bool { [9, 10, 12, 13, 32].contains(unit) }
        enum State { case beforeName, name, afterName, beforeValue, double, single, unquoted, afterQuoted, selfClosing }
        var state = State.beforeName, index = start
        while index < units.count {
            let unit = units[index]
            switch state {
            case .beforeName, .afterName:
                if unit == 62 { return index }
                if unit == 47 { state = .selfClosing }
                else if state == .afterName, unit == 61 { state = .beforeValue }
                else if !space(unit) { state = .name }
            case .name:
                if unit == 62 { return index }
                if space(unit) { state = .afterName } else if unit == 47 { state = .selfClosing } else if unit == 61 { state = .beforeValue }
            case .beforeValue:
                if unit == 62 { return index }
                if unit == 34 { state = .double } else if unit == 39 { state = .single } else if !space(unit) { state = .unquoted }
            case .double: if unit == 34 { state = .afterQuoted }
            case .single: if unit == 39 { state = .afterQuoted }
            case .unquoted:
                if unit == 62 { return index }
                if space(unit) { state = .beforeName }
            case .afterQuoted:
                if unit == 62 { return index }
                if unit == 47 { state = .selfClosing } else { state = .beforeName; if !space(unit) { continue } }
            case .selfClosing:
                if unit == 62 { return index }
                state = .beforeName; continue
            }
            index += 1
        }
        return nil
    }

    /// JavaScriptCore's message when `script` does not parse as a classic script, or nil; nothing is run.
    static func syntaxError(_ script: String) -> String? {
        guard let context = JSGlobalContextCreate(nil) else { return "无法建立检查环境" }
        defer { JSGlobalContextRelease(context) }
        let source = JSStringCreateWithCFString(script as CFString)
        defer { JSStringRelease(source) }
        var exception: JSValueRef?
        if JSCheckScriptSyntax(context, source, nil, 1, &exception) { return nil }
        guard let exception, let text = JSValueToStringCopy(context, exception, nil) else { return "SyntaxError" }
        defer { JSStringRelease(text) }
        return JSStringCopyCFString(nil, text) as String
    }
}
