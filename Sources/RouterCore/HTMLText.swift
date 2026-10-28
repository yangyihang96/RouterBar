import Foundation

/// What a browser shows for text a page inserts as HTML (jQuery .html(), innerHTML), worked out from the HTML parser's
/// rules (WHATWG HTML: tokenization, and tree construction "in body") and the default rendering, without running or
/// loading anything:
/// - Tags, comments and doctypes show nothing, one left open at the end included; quoted attribute values may hold ">";
///   a comment ends at "-->" or "--!>"; CR LF and a lone CR are read as LF.
/// - Character references are decoded with the full named list (Resources/HTMLEntities.json, from
///   html.spec.whatwg.org/entities.json) and the numeric rules; raw text (xmp, plaintext) shows them as written.
/// - The tree is built as the parser builds it "in body": the stack of open elements with its scopes, implied end tags,
///   the list of active formatting elements (opened again after a block closed them), and the adoption agency, which
///   can move what was already written; an end tag with nothing open to close is ignored. Then the tree is laid out: a
///   shown block starts and ends a line, <br> breaks one, b and strong make text bold and a makes it a link.
/// - script, style, template, noscript and the other elements the default style hides show nothing; xmp, pre, listing,
///   plaintext and textarea keep their white space and line breaks; elsewhere white space shows as one space, with none
///   at the start or end of a line, and an image keeps the spaces on either side apart.
/// The lines are the ones the browser draws (checked against Chrome's layout): unlike innerText, a <br> before a block or
/// at the end, and a final line feed in a pre, make no line of their own; margins (of p, headings, lists) are gaps, not
/// lines, and are left out.
/// Not followed: tables (their tags are ignored, so their text stays where the parser would move it before the table),
/// forms and select, SVG and MathML, style sheets, and what attributes do (hidden, style, open and the rest); attributes
/// only decide which formatting elements count as the same.
public enum HTMLText {
    public enum Token: Sendable, Equatable {
        /// Text with its character references decoded (raw text keeps them as written).
        case text(String)
        /// A start or end tag; a start tag's attributes, names in lower case, the first of a repeated name kept, values
        /// decoded. They decide only which formatting elements count as the same (the Noah's Ark clause).
        case tag(name: String, closing: Bool, attributes: [String: String] = [:])
        /// A comment or doctype: nothing shows, but it stands between a <pre> and a line feed that would be dropped.
        case comment
    }

    /// The named character references, without the "&"; legacy names appear with and without ";".
    static let entities: [String: String] = {
        guard let url = Bundle.module.url(forResource: "HTMLEntities", withExtension: "json"), let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()

    /// The numeric references 0x80–0x9F that stand for Windows-1252 characters.
    static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030,
        0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022,
        0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178]

    // MARK: Character references

    /// Decodes character references; in an attribute value, a named reference without ";" that is followed by "=" or a
    /// letter or digit stays as written ("historical reasons" in the named character reference state).
    public static func decode(_ text: String, inAttribute: Bool = false) -> String {
        guard text.contains("&") else { return text }
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func alphanumeric(_ c: Unicode.Scalar) -> Bool { c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c)) }
        while i < s.count {
            guard s[i] == "&" else { out.append(s[i]); i += 1; continue }
            if i + 1 < s.count, s[i + 1] == "#" {
                var j = i + 2, radix: UInt64 = 10
                if j < s.count, s[j] == "x" || s[j] == "X" { radix = 16; j += 1 }
                let start = j
                var value: UInt64 = 0
                while j < s.count, let digit = UInt64(String(s[j]), radix: Int(radix)), s[j].isASCII {
                    value = min(value * radix + digit, 0x110000); j += 1
                }
                guard j > start else { out.append("&"); i += 1; continue }
                if j < s.count, s[j] == ";" { j += 1 }
                let code = UInt32(value)
                if code == 0 || code > 0x10FFFF || (0xD800...0xDFFF).contains(code) {
                    out.append("\u{FFFD}")
                } else {
                    out.append(Unicode.Scalar(windows1252[code] ?? code) ?? "\u{FFFD}")
                }
                i = j
                continue
            }
            // The longest name in the list, as the named reference state consumes it.
            var name = "", best: (length: Int, characters: String, terminated: Bool)?
            var j = i + 1
            while j < s.count, name.count < 32 {
                let c = s[j]
                if c == ";" {
                    if let characters = entities[name + ";"] { best = (j + 1 - i, characters, true) }
                    break
                }
                guard alphanumeric(c) else { break }
                name.unicodeScalars.append(c)
                j += 1
                if let characters = entities[name] { best = (j - i, characters, false) }
            }
            if let found = best, inAttribute, !found.terminated, i + found.length < s.count,
               s[i + found.length] == "=" || alphanumeric(s[i + found.length]) {
                best = nil
            }
            if let best {
                out.append(contentsOf: best.characters.unicodeScalars)
                i += best.length
            } else {
                out.append("&")
                i += 1
            }
        }
        return String(out)
    }

    // MARK: Tokens

    /// Elements whose content is read as raw text up to their end tag (plaintext: to the end), and whether character
    /// references in it are decoded (RCDATA). noscript is raw text because the router's pages run scripts.
    static let rawText: [String: Bool] = ["iframe": false, "noembed": false, "noframes": false, "noscript": false, "plaintext": false,
                                          "script": false, "style": false, "textarea": true, "title": true, "xmp": false]

    public static func tokens(_ html: String) -> [Token] {
        // Input stream preprocessing: CR LF and a lone CR become LF.
        var s: [Unicode.Scalar] = []
        var afterCR = false
        for c in html.unicodeScalars {
            if !(c == "\n" && afterCR) { s.append(c == "\r" ? "\n" : c) }
            afterCR = c == "\r"
        }
        var tokens: [Token] = []
        var text = String.UnicodeScalarView()
        var i = 0
        func letter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
        func space(_ c: Unicode.Scalar) -> Bool { [" ", "\t", "\n", "\u{0C}"].contains(c) }
        /// Tag and attribute names are lowered for ASCII letters only.
        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar { ("A"..."Z").contains(c) ? Unicode.Scalar(c.value + 32) ?? c : c }
        func flush() { if !text.isEmpty { tokens.append(.text(decode(String(text)))); text = .init() } }
        func starts(_ word: String, at index: Int) -> Bool {
            let w = Array(word.unicodeScalars)
            guard index + w.count <= s.count else { return false }
            return zip(s[index..<index + w.count], w).allSatisfy { String($0).lowercased() == String($1).lowercased() }
        }
        /// The index after the next `mark` from `index`, or nil at the end.
        func past(_ mark: String, from index: Int) -> Int? {
            var j = index
            while j < s.count { if starts(mark, at: j) { return j + mark.unicodeScalars.count }; j += 1 }
            return nil
        }
        while i < s.count {
            let c = s[i]
            guard c == "<", i + 1 < s.count else { text.append(c); i += 1; continue }
            let next = s[i + 1]
            if letter(next) || (next == "/" && i + 2 < s.count && letter(s[i + 2])) {
                // A start or end tag: name, then attributes, whose quoted values may hold ">".
                let closing = next == "/"
                var j = i + (closing ? 2 : 1)
                var nameScalars = String.UnicodeScalarView()
                while j < s.count, !space(s[j]), s[j] != "/", s[j] != ">" { nameScalars.append(lower(s[j])); j += 1 }
                var attributes: [String: String] = [:]
                var ended = false
                while j < s.count {
                    if space(s[j]) || s[j] == "/" { j += 1; continue }
                    if s[j] == ">" { j += 1; ended = true; break }
                    // An attribute name, of which an "=" at the start is a part.
                    var attribute = String.UnicodeScalarView()
                    if s[j] == "=" { attribute.append("="); j += 1 }
                    while j < s.count, !space(s[j]), s[j] != "/", s[j] != ">", s[j] != "=" { attribute.append(lower(s[j])); j += 1 }
                    while j < s.count, space(s[j]) { j += 1 }
                    var value = ""
                    if j < s.count, s[j] == "=" {
                        j += 1
                        while j < s.count, space(s[j]) { j += 1 }
                        let start: Int
                        if j < s.count, s[j] == "\"" || s[j] == "'" {
                            let quote = s[j]
                            j += 1
                            start = j
                            while j < s.count, s[j] != quote { j += 1 }
                            value = String(String.UnicodeScalarView(s[start..<j]))
                            if j < s.count { j += 1 }
                        } else {
                            start = j
                            while j < s.count, !space(s[j]), s[j] != ">" { j += 1 }
                            value = String(String.UnicodeScalarView(s[start..<j]))
                        }
                        value = decode(value, inAttribute: true)
                    }
                    if attributes[String(attribute)] == nil { attributes[String(attribute)] = value }
                }
                // A tag still open at the end is dropped, with whatever follows it.
                guard ended else { flush(); return tokens }
                flush()
                let name = String(nameScalars)
                tokens.append(.tag(name: name, closing: closing, attributes: closing ? [:] : attributes))
                i = j
                if !closing, let decoded = rawText[name] {
                    // Raw text, up to "</name" followed by white space, "/" or ">".
                    var k = name == "plaintext" ? s.count : i
                    while k < s.count, !(starts("</" + name, at: k) && k + name.count + 2 < s.count
                                          && (space(s[k + name.count + 2]) || ["/", ">"].contains(s[k + name.count + 2]))) { k += 1 }
                    let raw = String(String.UnicodeScalarView(s[i..<k]))
                    if !raw.isEmpty { tokens.append(.text(decoded ? decode(raw) : raw)) }
                    i = k
                }
            } else if starts("<!--", at: i) {
                flush()
                tokens.append(.comment)
                // "<!-->" and "<!--->" end at once; otherwise the comment ends at "-->" or "--!>", or runs to the end.
                let j = i + 4
                if starts(">", at: j) { i = j + 1 } else if starts("->", at: j) { i = j + 2 } else {
                    var k = j
                    while k < s.count, !starts("-->", at: k), !starts("--!>", at: k) { k += 1 }
                    i = k == s.count ? k : k + (s[k + 2] == ">" ? 3 : 4)
                }
            } else if next == "!" || next == "?" || (next == "/" && i + 2 < s.count) {
                // A doctype or bogus comment up to ">"; "</>" is no token at all.
                flush()
                if next != "/" || s[i + 2] != ">" { tokens.append(.comment) }
                i = past(">", from: i + 2) ?? s.count
            } else {
                text.append(c)
                i += 1
            }
        }
        flush()
        return tokens
    }

    // MARK: Elements

    static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    /// The special elements: an end tag looking for its element stops at them, and so does the adoption agency's search
    /// for a furthest block. search is not among them: Chrome closes a p for it but passes over it here (measured).
    static let special: Set<String> = headings.union([
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br", "button", "caption",
        "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset", "figcaption", "figure", "footer",
        "form", "frame", "frameset", "head", "header", "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li", "link",
        "listing", "main", "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript", "object", "ol", "p", "param",
        "plaintext", "pre", "script", "section", "select", "source", "style", "summary", "table", "tbody", "td",
        "template", "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul", "wbr", "xmp"])
    /// Where looking for an element in scope stops.
    static let scopeLimits: Set<String> = ["applet", "caption", "html", "marquee", "object", "table", "td", "template", "th"]
    /// What "generate implied end tags" closes.
    static let impliedEnds: Set<String> = ["dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc"]
    /// Start tags that first close a p that is open (in button scope), and have no other rule of their own.
    static let paragraphClosers: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption",
        "figure", "footer", "header", "hgroup", "main", "menu", "nav", "ol", "p", "search", "section", "summary", "ul"]
    /// End tags that close their element only when it is open in scope, and are ignored otherwise.
    static let scopedEnds: Set<String> = [
        "address", "article", "aside", "blockquote", "button", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "header", "hgroup", "listing", "main", "menu", "nav", "ol", "pre", "search", "section",
        "summary", "ul"]
    /// The formatting elements: the parser opens them again after a block closed them, and closes them with the adoption
    /// agency. Of these only a, b and strong change how text shows here.
    static let formatting: Set<String> = ["a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u"]
    /// Tags the "in body" rules ignore, and the table tags, which are not followed.
    static let ignoredStart: Set<String> = ["body", "caption", "col", "colgroup", "frame", "frameset", "head", "html", "table", "tbody",
                                            "td", "tfoot", "th", "thead", "tr"]
    static let ignoredEnd: Set<String> = ["body", "caption", "col", "colgroup", "frame", "head", "html", "table", "tbody", "td", "tfoot",
                                          "th", "thead", "tr"]
    /// Elements the default style lays out as blocks (display: block or list-item).
    static let blocks: Set<String> = headings.union([
        "address", "article", "aside", "blockquote", "center", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "header", "hgroup", "hr", "legend", "li", "listing", "main", "menu", "nav", "ol",
        "p", "plaintext", "pre", "search", "section", "summary", "ul", "xmp"])
    /// Elements that keep their white space (white-space: pre, and the text of a textarea).
    static let preformatted: Set<String> = ["listing", "plaintext", "pre", "textarea", "xmp"]
    /// Elements that show nothing of what they hold: display: none in the default style (a dialog without open, noscript
    /// while scripts run), template contents, and an iframe, whose text is never shown.
    static let hidden: Set<String> = ["datalist", "dialog", "iframe", "noembed", "noframes", "noscript", "rp", "script", "style",
                                      "template", "title"]
    /// Replaced elements that take a place on the line though nothing of them shows here: an image that does not load is
    /// 0×0, yet the spaces on either side stay apart, and a block holding one has a line.
    static let atomic: Set<String> = ["img", "input"]

    // MARK: Tree

    /// A node of the tree the parser builds: an element with its children, or text.
    private final class Node {
        let name: String?
        /// The attributes of the tag the element was made for, which copies of it keep.
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        weak var parent: Node?

        init(_ name: String?, _ attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }

        func append(_ child: Node) {
            child.parent?.children.removeAll { $0 === child }
            child.parent = self
            children.append(child)
        }
    }

    /// Tree construction "in body" (WHATWG HTML, 13.2.6.4.7) for the elements the page text can hold: the stack of open
    /// elements, the list of active formatting elements with its markers, the adoption agency and the reconstruction of
    /// formatting elements, so that text ends up under the elements a browser puts it under.
    private struct TreeBuilder {
        let root = Node(nil)
        var open: [Node] = []
        /// The list of active formatting elements; nil is a marker.
        var active: [Node?] = []
        var form: Node?
        /// A line feed right after pre, listing and textarea is dropped; in a raw text element the next end tag closes it.
        var dropNewline = false, rawText = false

        /// The HTML is written into the elements of `context`, outermost first.
        init(context: [String]) {
            var parent = root
            for name in context {
                let node = Node(name)
                parent.append(node)
                open.append(node)
                parent = node
            }
        }

        var current: Node { open.last ?? root }
        var hasTemplate: Bool { open.contains { $0.name == "template" } }

        mutating func take(_ token: Token) {
            let newline = dropNewline
            dropNewline = false
            switch token {
            case .comment: break
            case .text(var text):
                if newline, text.hasPrefix("\n") { text.removeFirst() }
                guard !text.isEmpty else { return }
                if !rawText { reconstruct() }
                insert(text)
            case .tag(let name, let closing, let attributes):
                if rawText, closing { rawText = false; pop(); return }
                if closing { end(name) } else { start(name == "image" ? "img" : name, attributes) }
            }
        }

        mutating func start(_ name: String, _ attributes: [String: String]) {
            switch name {
            case _ where HTMLText.ignoredStart.contains(name): return
            case "base", "basefont", "bgsound", "link", "meta", "param", "source", "track":
                insertElement(name, attributes); pop()
            case "iframe", "noembed", "noframes", "noscript", "script", "style", "title":
                insertElement(name, attributes); rawText = true
            case "textarea":
                insertElement(name, attributes); rawText = true; dropNewline = true
            case "xmp":
                closeParagraph(); reconstruct(); insertElement(name, attributes); rawText = true
            case "template":
                insertElement(name, attributes); active.append(nil)
            case "li":
                closeItem(["li"]); closeParagraph(); insertElement(name, attributes)
            case "dd", "dt":
                closeItem(["dd", "dt"]); closeParagraph(); insertElement(name, attributes)
            case _ where HTMLText.headings.contains(name):
                closeParagraph()
                if let last = current.name, HTMLText.headings.contains(last) { pop() }
                insertElement(name, attributes)
            case "pre", "listing":
                closeParagraph(); insertElement(name, attributes); dropNewline = true
            case "form":
                guard form == nil || hasTemplate else { return }
                closeParagraph()
                let node = insertElement(name, attributes)
                if !hasTemplate { form = node }
            case "plaintext", "hr":
                closeParagraph(); insertElement(name, attributes)
                if name == "hr" { pop() }
            case "button":
                if inScope(["button"]) { impliedEnds(); pop(until: ["button"]) }
                reconstruct(); insertElement(name, attributes)
            case "a":
                // A second a first closes the one that is open.
                if let previous = lastActive("a") {
                    adoptionAgency("a")
                    active.removeAll { $0 === previous }
                    open.removeAll { $0 === previous }
                }
                reconstruct(); pushFormatting(insertElement(name, attributes))
            case "nobr":
                reconstruct()
                if inScope(["nobr"]) { adoptionAgency("nobr"); reconstruct() }
                pushFormatting(insertElement(name, attributes))
            case _ where HTMLText.formatting.contains(name):
                reconstruct(); pushFormatting(insertElement(name, attributes))
            case "applet", "marquee", "object":
                reconstruct(); insertElement(name, attributes); active.append(nil)
            case "area", "br", "embed", "img", "input", "keygen", "wbr":
                reconstruct(); insertElement(name, attributes); pop()
            case "option", "optgroup":
                if current.name == "option" { pop() }
                reconstruct(); insertElement(name, attributes)
            case "rb", "rtc":
                if inScope(["ruby"]) { impliedEnds() }
                insertElement(name, attributes)
            case "rp", "rt":
                if inScope(["ruby"]) { impliedEnds(except: "rtc") }
                insertElement(name, attributes)
            case _ where HTMLText.paragraphClosers.contains(name):
                closeParagraph(); insertElement(name, attributes)
            default:
                reconstruct(); insertElement(name, attributes)
            }
        }

        mutating func end(_ name: String) {
            switch name {
            case _ where HTMLText.ignoredEnd.contains(name): return
            case "template":
                guard hasTemplate else { return }
                impliedEnds(); pop(until: ["template"]); clearToMarker()
            case "form":
                if hasTemplate {
                    guard inScope(["form"]) else { return }
                    impliedEnds(); pop(until: ["form"])
                } else {
                    let node = form
                    form = nil
                    guard let node, inScope(node) else { return }
                    impliedEnds()
                    open.removeAll { $0 === node }
                }
            case "p":
                // With no p open, the parser makes an empty one, which is still a block.
                if !inScope(["p"], or: ["button"]) { insertElement("p") }
                closeParagraph()
            case "li":
                if inScope(["li"], or: ["ol", "ul"]) { impliedEnds(except: "li"); pop(until: ["li"]) }
            case "dd", "dt":
                if inScope([name]) { impliedEnds(except: name); pop(until: [name]) }
            case _ where HTMLText.headings.contains(name):
                if inScope(HTMLText.headings) { impliedEnds(); pop(until: HTMLText.headings) }
            case _ where HTMLText.formatting.contains(name):
                adoptionAgency(name)
            case "applet", "marquee", "object":
                if inScope([name]) { impliedEnds(); pop(until: [name]); clearToMarker() }
            case "br":
                reconstruct(); insertElement("br"); pop()
            case _ where HTMLText.scopedEnds.contains(name):
                if inScope([name]) { impliedEnds(); pop(until: [name]) }
            default:
                anyOtherEnd(name)
            }
        }

        /// Any other end tag closes the nearest open element of its name, unless a special element comes first.
        mutating func anyOtherEnd(_ name: String) {
            for index in open.indices.reversed() {
                let node = open[index]
                if node.name == name {
                    impliedEnds(except: name)
                    while open.count > index { pop() }
                    return
                }
                if HTMLText.special.contains(node.name ?? "") { return }
            }
        }

        /// The adoption agency: the end tag of a formatting element closes it even when elements were opened inside it,
        /// which then go on under a copy of it, inside the first special element among them.
        mutating func adoptionAgency(_ subject: String) {
            if let node = open.last, node.name == subject, !active.contains(where: { $0 === node }) { pop(); return }
            for _ in 0..<8 {
                guard let element = lastActive(subject) else { return anyOtherEnd(subject) }
                guard let index = open.firstIndex(where: { $0 === element }) else {
                    active.removeAll { $0 === element }
                    return
                }
                guard inScope(element) else { return }
                guard let blockIndex = open.indices.first(where: { $0 > index && HTMLText.special.contains(open[$0].name ?? "") }) else {
                    while open.count > index { pop() }
                    active.removeAll { $0 === element }
                    return
                }
                let furthestBlock = open[blockIndex]
                let commonAncestor = index > 0 ? open[index - 1] : root
                var bookmark = active.firstIndex { $0 === element } ?? active.count
                var lastNode = furthestBlock, nodeIndex = blockIndex, inner = 0
                while true {
                    inner += 1
                    nodeIndex -= 1
                    let node = open[nodeIndex]
                    if node === element { break }
                    if inner > 3, let at = active.firstIndex(where: { $0 === node }) {
                        active.remove(at: at)
                        if at < bookmark { bookmark -= 1 }
                    }
                    guard let at = active.firstIndex(where: { $0 === node }) else {
                        open.remove(at: nodeIndex)
                        continue
                    }
                    let copy = Node(node.name, node.attributes)
                    active[at] = copy
                    open[nodeIndex] = copy
                    if lastNode === furthestBlock { bookmark = at + 1 }
                    copy.append(lastNode)
                    lastNode = copy
                }
                commonAncestor.append(lastNode)
                // All of furthest block's children go to the copy at once.
                let copy = Node(element.name, element.attributes)
                copy.children = furthestBlock.children
                furthestBlock.children = []
                for child in copy.children { child.parent = copy }
                furthestBlock.append(copy)
                if let at = active.firstIndex(where: { $0 === element }) {
                    active.remove(at: at)
                    if at < bookmark { bookmark -= 1 }
                }
                active.insert(copy, at: min(bookmark, active.count))
                open.removeAll { $0 === element }
                if let at = open.firstIndex(where: { $0 === furthestBlock }) { open.insert(copy, at: at + 1) }
            }
        }

        /// Formatting elements a block closed are opened again where text goes next, up to the last marker.
        mutating func reconstruct() {
            guard let last = active.last, let last, !isOpen(last) else { return }
            var start = active.count - 1
            while start > 0, let entry = active[start - 1], !isOpen(entry) { start -= 1 }
            for index in start..<active.count {
                guard let entry = active[index] else { continue }
                active[index] = insertElement(entry.name ?? "", entry.attributes)
            }
        }

        mutating func pushFormatting(_ node: Node) {
            // Noah's Ark: of the same element (name and attributes) after the last marker, at most three stay in the list.
            var same: [Int] = []
            for index in active.indices.reversed() {
                guard let entry = active[index] else { break }
                if entry.name == node.name, entry.attributes == node.attributes { same.append(index) }
            }
            if same.count >= 3, let earliest = same.last { active.remove(at: earliest) }
            active.append(node)
        }

        /// Whether the node is on the stack of open elements; formatting elements are usually near the top.
        func isOpen(_ node: Node) -> Bool { open.lastIndex { $0 === node } != nil }

        func lastActive(_ name: String) -> Node? {
            for entry in active.reversed() {
                guard let entry else { return nil }
                if entry.name == name { return entry }
            }
            return nil
        }

        mutating func clearToMarker() {
            while let entry = active.popLast() { if entry == nil { return } }
        }

        /// Before a new li (dd, dt): the open one of the kind closes, unless a special element other than address, div
        /// and p comes first.
        mutating func closeItem(_ names: Set<String>) {
            for node in open.reversed() {
                let name = node.name ?? ""
                if names.contains(name) { impliedEnds(except: name); pop(until: [name]); return }
                if HTMLText.special.contains(name), !["address", "div", "p"].contains(name) { return }
            }
        }

        mutating func closeParagraph() {
            guard inScope(["p"], or: ["button"]) else { return }
            impliedEnds(except: "p")
            pop(until: ["p"])
        }

        func inScope(_ names: Set<String>, or limits: Set<String> = []) -> Bool {
            for node in open.reversed() {
                let name = node.name ?? ""
                if names.contains(name) { return true }
                if HTMLText.scopeLimits.contains(name) || limits.contains(name) { return false }
            }
            return false
        }

        func inScope(_ target: Node) -> Bool {
            for node in open.reversed() {
                if node === target { return true }
                if HTMLText.scopeLimits.contains(node.name ?? "") { return false }
            }
            return false
        }

        mutating func impliedEnds(except name: String? = nil) {
            while let last = open.last?.name, HTMLText.impliedEnds.contains(last), last != name { pop() }
        }

        mutating func pop() { if !open.isEmpty { open.removeLast() } }

        mutating func pop(until names: Set<String>) {
            while let node = open.popLast() { if names.contains(node.name ?? "") { return } }
        }

        /// Once the stack of open elements (with the root element) is deeper than 512, Chrome puts a new element next to
        /// the current node instead of inside it (kMaximumHTMLParserDOMTreeDepth; measured), which also keeps the tree
        /// that is laid out shallow. Text still goes into the current node.
        @discardableResult
        mutating func insertElement(_ name: String, _ attributes: [String: String] = [:]) -> Node {
            let node = Node(name, attributes)
            (open.count >= 512 ? current.parent ?? root : current).append(node)
            open.append(node)
            return node
        }

        mutating func insert(_ text: String) {
            if let last = current.children.last, last.name == nil { last.text += text; return }
            let node = Node(nil)
            node.text = text
            current.append(node)
        }
    }

    // MARK: Layout

    /// One piece of shown text with its style.
    struct Piece { var text: String; var bold: Bool; var link: Bool }

    /// The text as laid out, for HTML written into the elements `context` (outermost first, such as ["td", "div"] for a
    /// <div> in a table cell): lines from <br>, blocks and preformatted line feeds; elsewhere white space collapsed across
    /// pieces, with none at the start or end of a line; and no empty line for a final line break.
    static func layout(_ tokens: [Token], inside context: [String] = []) -> [Piece] {
        var builder = TreeBuilder(context: context)
        for token in tokens { builder.take(token) }
        var renderer = Renderer()
        renderer.render(builder.root)
        // The tree is taken apart one node at a time, so that a deep one is not released recursively.
        var nodes = [builder.root]
        while let node = nodes.popLast() {
            nodes += node.children
            node.children = []
        }
        return renderer.finish()
    }

    /// Lays out the tree as the default style shows it.
    private struct Renderer {
        var pieces: [Piece] = []
        /// trailingSpace: the text ends with a collapsible space, the only kind removed at the end of a line.
        var lineHasText = false, pendingBreak = false, trailingBreaks = 0, trailingSpace = false

        /// An element being laid out: the next of its children, the style it passes on, and whether it is a block.
        struct Frame { let node: Node; var next = 0; let preformatted: Bool; let bold: Bool; let link: Bool; let block: Bool }

        /// Walks the tree with a stack of its own, so that deep nesting does not deepen the call stack.
        mutating func render(_ root: Node) {
            var stack = [Frame(node: root, preformatted: false, bold: false, link: false, block: false)]
            while let top = stack.last {
                guard top.next < top.node.children.count else {
                    stack.removeLast()
                    if top.block { endLine() }
                    continue
                }
                let child = top.node.children[top.next]
                stack[stack.count - 1].next += 1
                guard let name = child.name else {
                    show(child.text, preformatted: top.preformatted, bold: top.bold, link: top.link)
                    continue
                }
                if HTMLText.hidden.contains(name) { continue }
                if name == "br" { lineBreak(bold: top.bold, link: top.link); continue }
                if HTMLText.atomic.contains(name) { atomic(bold: top.bold, link: top.link); continue }
                let block = HTMLText.blocks.contains(name)
                if block { endLine() }
                stack.append(Frame(node: child, preformatted: top.preformatted || HTMLText.preformatted.contains(name),
                                   bold: top.bold || name == "b" || name == "strong", link: top.link || name == "a", block: block))
            }
        }

        mutating func show(_ text: String, preformatted: Bool, bold: Bool, link: Bool) {
            for c in text.unicodeScalars {
                if preformatted {
                    // white-space: pre: a line feed breaks the line, and a carriage return shows as a space.
                    if c == "\n" { lineBreak(bold: bold, link: link) } else { character(c == "\r" ? " " : c, bold: bold, link: link) }
                } else if [" ", "\t", "\n", "\r", "\u{0C}"].contains(c) {
                    guard lineHasText, !pendingBreak, !trailingSpace else { continue }
                    append(" ", bold: bold, link: link)
                    trailingSpace = true
                } else {
                    character(c, bold: bold, link: link)
                }
            }
        }

        /// A character that shows, after the line break a block left pending.
        mutating func character(_ c: Unicode.Scalar, bold: Bool, link: Bool) {
            startLine(bold: bold, link: link)
            append(String(c), bold: bold, link: link)
        }

        /// An image or input: nothing shows, but the line has content, and a space after it stays.
        mutating func atomic(bold: Bool, link: Bool) {
            startLine(bold: bold, link: link)
            trailingSpace = false
        }

        mutating func startLine(bold: Bool, link: Bool) {
            if pendingBreak { trimSpace(); append("\n", bold: bold, link: link) }
            pendingBreak = false; trailingBreaks = 0; lineHasText = true
        }

        /// <br>, or a line feed in preformatted text: the line ends here, after any line break a block left pending.
        mutating func lineBreak(bold: Bool, link: Bool) {
            if pendingBreak { trimSpace(); append("\n", bold: bold, link: link) }
            pendingBreak = false
            trimSpace()
            append("\n", bold: bold, link: link)
            lineHasText = false; trailingBreaks += 1
        }

        /// The start or end of a block: what follows starts a new line, if this one has text.
        mutating func endLine() {
            trimSpace()
            if lineHasText { pendingBreak = true }
        }

        mutating func append(_ text: String, bold: Bool, link: Bool) {
            trailingSpace = false
            if let last = pieces.last, last.bold == bold, last.link == link { pieces[pieces.count - 1].text += text }
            else { pieces.append(Piece(text: text, bold: bold, link: link)) }
        }

        /// Removes a collapsible space at the end of a line; preformatted spaces stay.
        mutating func trimSpace() {
            guard trailingSpace, let last = pieces.indices.last else { return }
            trailingSpace = false
            pieces[last].text.removeLast()
            if pieces[last].text.isEmpty { pieces.removeLast() }
        }

        mutating func finish() -> [Piece] {
            trimSpace()
            // A final line break makes no empty line.
            if trailingBreaks > 0, let last = pieces.indices.last, pieces[last].text.hasSuffix("\n") {
                pieces[last].text.removeLast()
                if pieces[last].text.isEmpty { pieces.removeLast() }
            }
            return pieces
        }
    }

    public static func visible(_ html: String, inside context: [String] = []) -> String {
        layout(tokens(html), inside: context).map(\.text).joined()
    }
}
