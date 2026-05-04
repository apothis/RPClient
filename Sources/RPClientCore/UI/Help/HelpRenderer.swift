import AppKit

/// Block-aware markdown renderer for the help window. The chat-side
/// [Markdown](Markdown.swift) renderer only handles inline patterns + fenced
/// code blocks because that's all chat turns ever need; help docs need
/// headings, lists, and internal links as well, so this renderer parses
/// line-by-line and reuses the same inline pass for paragraph text.
///
/// Anchors. Each heading is tagged with a `helpAnchor` attribute carrying its
/// slug. The window controller can then locate the heading's range and
/// `scrollRangeToVisible` to it. Internal links use the `.link` attribute with
/// a custom `rpclient-help:` URL scheme; the controller's NSTextView delegate
/// resolves that scheme back into a navigation event rather than calling out
/// to the system handler.
enum HelpRenderer {

    /// Custom attribute that marks the start of a heading anchor. Value is the
    /// slug string. Persisted on the first character of the heading line.
    static let helpAnchorAttr = NSAttributedString.Key("rpclient.help.anchor")

    /// URL scheme used for in-help navigation. Format:
    ///   `rpclient-help:page-id`           (jump to top of another page)
    ///   `rpclient-help:page-id#anchor`    (jump to anchor in another page)
    ///   `rpclient-help:#anchor`           (jump to anchor on the current page)
    static let linkScheme = "rpclient-help"

    struct Result {
        let attributed: NSAttributedString
        /// Map of anchor slug → character location in `attributed`. Lets the
        /// controller scroll to a target without re-walking the string.
        let anchors: [String: Int]
    }

    static func render(_ md: String) -> Result {
        let baseSize: CGFloat = 13
        let baseFont = NSFont.systemFont(ofSize: baseSize)
        let out = NSMutableAttributedString()
        var anchors: [String: Int] = [:]

        let lines = md.components(separatedBy: "\n")
        var i = 0
        var firstBlock = true

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line: paragraph break — collapsed by the paragraph
            // styles, no need to emit anything explicit.
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3))
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip closing fence
                if !firstBlock { out.append(blockSpacer(baseFont)) }
                out.append(renderCodeBlock(lang: lang, code: code.joined(separator: "\n"), baseFont: baseFont))
                firstBlock = false
                continue
            }

            // Heading (#, ##, ###).
            if let (level, text) = parseHeading(line) {
                if !firstBlock { out.append(blockSpacer(baseFont)) }
                let slug = slugify(text)
                let location = out.length
                anchors[slug] = location
                out.append(renderHeading(level: level, text: text, baseFont: baseFont, slug: slug))
                firstBlock = false
                i += 1
                continue
            }

            // Bullet list (consume contiguous bullet lines).
            if isBullet(line) {
                var items: [String] = []
                while i < lines.count && isBullet(lines[i]) {
                    items.append(stripBulletPrefix(lines[i]))
                    i += 1
                }
                if !firstBlock { out.append(blockSpacer(baseFont)) }
                out.append(renderBulletList(items: items, baseFont: baseFont))
                firstBlock = false
                continue
            }

            // Numbered list.
            if isNumbered(line) {
                var items: [String] = []
                while i < lines.count && isNumbered(lines[i]) {
                    items.append(stripNumberedPrefix(lines[i]))
                    i += 1
                }
                if !firstBlock { out.append(blockSpacer(baseFont)) }
                out.append(renderNumberedList(items: items, baseFont: baseFont))
                firstBlock = false
                continue
            }

            // Paragraph: collect contiguous non-blank prose lines and join
            // with single spaces so the renderer's word wrap controls layout.
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("#") { break }
                if t.hasPrefix("```") { break }
                if isBullet(l) { break }
                if isNumbered(l) { break }
                para.append(l)
                i += 1
            }
            if !firstBlock { out.append(blockSpacer(baseFont)) }
            out.append(renderParagraph(text: para.joined(separator: " "), baseFont: baseFont))
            firstBlock = false
        }

        return Result(attributed: out, anchors: anchors)
    }

    // MARK: - Block parsers

    private static func parseHeading(_ line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 4 else { return nil }
        let after = trimmed.index(trimmed.startIndex, offsetBy: level)
        guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
        let text = String(trimmed[trimmed.index(after: after)...])
            .trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isBullet(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("- ") || t.hasPrefix("* ")
    }

    private static func stripBulletPrefix(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") { return String(t.dropFirst(2)) }
        if t.hasPrefix("* ") { return String(t.dropFirst(2)) }
        return t
    }

    private static func isNumbered(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // "1. " through "999. "
        guard let dot = t.firstIndex(of: ".") else { return false }
        let prefix = t[t.startIndex..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return false }
        let after = t.index(after: dot)
        return after < t.endIndex && t[after] == " "
    }

    private static func stripNumberedPrefix(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let dot = t.firstIndex(of: ".") else { return t }
        let after = t.index(after: dot)
        guard after < t.endIndex else { return t }
        return String(t[t.index(after: after)...])
    }

    // MARK: - Block renderers

    private static func renderHeading(
        level: Int, text: String, baseFont: NSFont, slug: String
    ) -> NSAttributedString {
        let size: CGFloat
        switch level {
        case 1: size = baseFont.pointSize + 10
        case 2: size = baseFont.pointSize + 5
        case 3: size = baseFont.pointSize + 2
        default: size = baseFont.pointSize + 1
        }
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = level == 1 ? 0 : 14
        para.paragraphSpacing = 6
        para.lineHeightMultiple = 1.2
        let attr = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para,
                helpAnchorAttr: slug,
            ]
        )
        attr.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: para]))
        return attr
    }

    private static func renderParagraph(text: String, baseFont: NSFont) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.4
        para.paragraphSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let s = NSMutableAttributedString(string: text, attributes: attrs)
        applyInline(s, baseFont: baseFont)
        s.append(NSAttributedString(string: "\n", attributes: attrs))
        return s
    }

    private static func renderBulletList(items: [String], baseFont: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.4
        para.paragraphSpacing = 2
        para.headIndent = 18
        para.firstLineHeadIndent = 0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        for (idx, item) in items.enumerated() {
            let line = NSMutableAttributedString(string: "•  \(item)", attributes: attrs)
            applyInline(line, baseFont: baseFont, contentRange: NSRange(location: 3, length: line.length - 3))
            out.append(line)
            if idx < items.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            } else {
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        return out
    }

    private static func renderNumberedList(items: [String], baseFont: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.4
        para.paragraphSpacing = 2
        para.headIndent = 22
        para.firstLineHeadIndent = 0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        for (idx, item) in items.enumerated() {
            let prefix = "\(idx + 1).  "
            let line = NSMutableAttributedString(string: prefix + item, attributes: attrs)
            applyInline(line, baseFont: baseFont, contentRange: NSRange(location: prefix.count, length: line.length - prefix.count))
            out.append(line)
            out.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        return out
    }

    private static func renderCodeBlock(lang: String, code: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(
            ofSize: max(11, baseFont.pointSize - 1), weight: .regular
        )

        let surface = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return dark
                ? NSColor(white: 0.12, alpha: 1.0)
                : NSColor(white: 0.95, alpha: 1.0)
        }

        if !lang.isEmpty {
            let labelPara = NSMutableParagraphStyle()
            labelPara.paragraphSpacingBefore = 0
            labelPara.paragraphSpacing = 0
            result.append(NSAttributedString(
                string: lang.uppercased() + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: max(9, baseFont.pointSize - 4), weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: labelPara,
                    .kern: 0.5
                ]
            ))
        }

        let codePara = NSMutableParagraphStyle()
        codePara.lineHeightMultiple = 1.25
        codePara.paragraphSpacing = 0

        let table = NSTextTable()
        table.numberOfColumns = 1
        let block = NSTextTableBlock(
            table: table, startingRow: 0, rowSpan: 1,
            startingColumn: 0, columnSpan: 1
        )
        block.backgroundColor = surface
        block.setWidth(12, type: .absoluteValueType, for: .padding)
        codePara.textBlocks = [block]

        result.append(NSAttributedString(
            string: code,
            attributes: [
                .font: mono,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: codePara
            ]
        ))
        result.append(NSAttributedString(
            string: "\n",
            attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor]
        ))
        return result
    }

    private static func blockSpacer(_ baseFont: NSFont) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 0
        para.lineHeightMultiple = 0.6
        return NSAttributedString(
            string: "\n",
            attributes: [.font: baseFont, .paragraphStyle: para]
        )
    }

    // MARK: - Inline pass

    /// Applies bold, italic, inline code, and link patterns to a string.
    /// Mutates `attr` in place. Each pass recomputes the search range from
    /// the current length, since link substitutions shrink the string and a
    /// stale baseRange would index past the end and throw `NSRangeException`.
    /// `contentRange` is accepted for callers (lists) that prepend a non-
    /// markdown prefix; it's used as the *initial* search range only.
    private static func applyInline(
        _ attr: NSMutableAttributedString,
        baseFont: NSFont,
        contentRange: NSRange? = nil
    ) {
        // Initial range — clamped to current length to be safe.
        var range = contentRange ?? NSRange(location: 0, length: attr.length)
        if NSMaxRange(range) > attr.length {
            range = NSRange(location: min(range.location, attr.length),
                            length: max(0, attr.length - range.location))
        }
        // Order: link first so its substitution shrinks the string; subsequent
        // passes recompute their search range from the new length below.
        applyLink(attr, range: range)
        applyPattern(attr, pattern: "\\*\\*([^*\\n]+)\\*\\*", build: { _ in
            [.font: bold(baseFont)]
        })
        applyPattern(attr, pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)", build: { _ in
            [.font: italic(baseFont)]
        })
        applyPattern(attr, pattern: "`([^`\\n]+)`", build: { _ in
            let mono = NSFont.monospacedSystemFont(
                ofSize: max(10, baseFont.pointSize - 1), weight: .regular
            )
            return [.font: mono, .backgroundColor: NSColor.quaternaryLabelColor]
        })
    }

    /// Replaces `[label](target)` with `label`, applying `.link` with our
    /// custom URL scheme so the NSTextView delegate can intercept clicks.
    private static func applyLink(_ attr: NSMutableAttributedString, range baseRange: NSRange) {
        guard let re = try? NSRegularExpression(
            pattern: "\\[([^\\]\\n]+)\\]\\(([^\\)\\n]+)\\)", options: []
        ) else { return }
        let matches = re.matches(in: attr.string, options: [], range: baseRange).reversed()
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let outer = m.range
            let labelRange = m.range(at: 1)
            let targetRange = m.range(at: 2)
            let ns = attr.string as NSString
            let label = ns.substring(with: labelRange)
            let target = ns.substring(with: targetRange)
            let url = resolveLink(target: target)
            var attrs = attr.attributes(at: outer.location, effectiveRange: nil)
            attrs[.link] = url
            attrs[.foregroundColor] = NSColor.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            let replacement = NSAttributedString(string: label, attributes: attrs)
            attr.replaceCharacters(in: outer, with: replacement)
        }
    }

    private static func resolveLink(target: String) -> URL {
        // Internal targets:
        //   "#anchor"            → rpclient-help:#anchor
        //   "page-id"            → rpclient-help:page-id
        //   "page-id#anchor"     → rpclient-help:page-id#anchor
        // External (anything starting with a scheme) passes through.
        if target.contains("://") {
            return URL(string: target) ?? URL(string: "about:blank")!
        }
        return URL(string: "\(linkScheme):\(target)") ?? URL(string: "about:blank")!
    }

    private static func applyPattern(
        _ attr: NSMutableAttributedString,
        pattern: String,
        build: (NSTextCheckingResult) -> [NSAttributedString.Key: Any]
    ) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        // Always recompute against the current length — earlier passes
        // (notably the link substitution) may have shrunk the string.
        let baseRange = NSRange(location: 0, length: attr.length)
        // Reverse iteration so earlier ranges aren't shifted by length-changing
        // substitutions performed for later matches.
        let matches = re.matches(in: attr.string, options: [], range: baseRange).reversed()
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let outer = m.range
            let inner = m.range(at: 1)
            let innerText = (attr.string as NSString).substring(with: inner)
            var attrs = attr.attributes(at: outer.location, effectiveRange: nil)
            for (k, v) in build(m) { attrs[k] = v }
            let replacement = NSAttributedString(string: innerText, attributes: attrs)
            attr.replaceCharacters(in: outer, with: replacement)
        }
    }

    private static func bold(_ base: NSFont) -> NSFont {
        let desc = base.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    private static func italic(_ base: NSFont) -> NSFont {
        let desc = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    // MARK: - Slugs

    /// Stable lowercase-hyphen slug derived from heading text. Keep this in
    /// sync with whatever links use as anchor targets — we don't share a
    /// constant with markdown source because authors hand-write the link
    /// targets and a divergence is the kind of thing the testkit page-load
    /// suite would notice via dead anchors (future enhancement).
    static func slugify(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
