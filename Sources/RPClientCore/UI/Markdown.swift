import AppKit

enum Markdown {
    /// Removes `<think>…</think>`, `<thinking>…</thinking>`, and the
    /// koboldcpp/Gemma `<|channel>thought…<channel|>` preamble.
    /// Convenience wrapper over `extractThinking(_:)` for non-UI callers
    /// that just want clean prose (Director, TTS, Summariser, Blurber,
    /// side-call generators). Per the no-fork rule pinned in
    /// Phase11ThinkExtractTests, this is exactly `extractThinking(s).body`.
    static func stripThinking(_ s: String) -> String {
        return extractThinking(s).body
    }

    /// Phase 11 §4.b — split the first thinking block from the body so
    /// the chat surface can render the body inline AND surface a
    /// "Thought for Xs" disclosure for the thinking content.
    ///
    /// Recognises the same four tag families as `stripThinking`:
    /// - `<think>…</think>`
    /// - `<thinking>…</thinking>`
    /// - koboldcpp/Gemma `<|channel>thought…<channel|>`
    /// - `<|begin_of_thought|>…<|end_of_thought|>`
    ///
    /// Empty / whitespace-only thinking blocks return `think = nil` —
    /// the empty pre-fill is harmless on Qwen3.6 (Phase 10 finding) and
    /// suppressing the disclosure keeps the chat surface quiet.
    /// Multiple blocks: the first non-empty one is returned as `think`;
    /// all blocks (including the first) are stripped from `body`.
    static func extractThinking(_ s: String) -> (think: String?, body: String) {
        let patterns = [
            "<think>([\\s\\S]*?)</think>",
            "<thinking>([\\s\\S]*?)</thinking>",
            "<\\|channel\\>thought([\\s\\S]*?)<channel\\|>",
            "<\\|begin_of_thought\\|>([\\s\\S]*?)<\\|end_of_thought\\|>"
        ]

        var firstThink: String?
        var body = s
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: []) else { continue }
            // Find the first match (with capture) before stripping all matches —
            // we need the captured content for the disclosure.
            if firstThink == nil {
                let range = NSRange(body.startIndex..., in: body)
                if let m = re.firstMatch(in: body, options: [], range: range),
                   m.numberOfRanges >= 2,
                   let cr = Range(m.range(at: 1), in: body) {
                    let captured = String(body[cr]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !captured.isEmpty {
                        firstThink = captured
                    }
                }
            }
            // Strip every match (regardless of which pattern produced
            // `firstThink`) so the body is fully cleaned.
            let stripRange = NSRange(body.startIndex..., in: body)
            body = re.stringByReplacingMatches(
                in: body, options: [], range: stripRange, withTemplate: ""
            )
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (firstThink, body)
    }

    /// Render a small subset of markdown: fenced code blocks, **bold**, *italic*, `code`.
    /// Marker characters are removed; everything else is kept verbatim.
    static func render(_ md: String, baseFont: NSFont) -> NSAttributedString {
        // 1. Extract fenced code blocks, replace with placeholders so inline
        //    patterns (bold/italic/inline code) can't match across them.
        var working = md
        var blocks: [(token: String, lang: String, code: String)] = []
        if let re = try? NSRegularExpression(
            pattern: "```([\\w+-]*)\\n?([\\s\\S]*?)```", options: []
        ) {
            while true {
                let full = NSRange(working.startIndex..., in: working)
                guard let m = re.firstMatch(in: working, options: [], range: full) else { break }
                let ns = working as NSString
                let lang = ns.substring(with: m.range(at: 1))
                var code = ns.substring(with: m.range(at: 2))
                if code.hasSuffix("\n") { code.removeLast() }
                let token = "\u{E000}CB\(blocks.count)\u{E001}"
                working = ns.replacingCharacters(in: m.range, with: token)
                blocks.append((token, lang, code))
            }
        }

        // 2. Build base attributed string with prose paragraph style.
        let prose = NSMutableParagraphStyle()
        prose.lineHeightMultiple = 1.35
        prose.paragraphSpacing = 6
        let attr = NSMutableAttributedString(
            string: working,
            attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: prose
            ]
        )

        // 3. Apply inline patterns. Placeholders contain no matchable markers.
        apply(attr, pattern: "\\*\\*([^*\\n]+)\\*\\*", build: { _ in
            [.font: bold(baseFont)]
        })
        // V2_UI_OVERHAUL §4.7 — italics in the chat transcript re-tint
        // to secondaryLabelColor. RP authors use *action* semantics; the
        // secondary tone reads as "narration aside, not dialogue" while
        // the italic face stays as the primary visual cue. Speech
        // (unmarked) keeps labelColor.
        apply(attr, pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)", build: { _ in
            [.font: italic(baseFont), .foregroundColor: NSColor.secondaryLabelColor]
        })
        apply(attr, pattern: "`([^`\\n]+)`", build: { _ in
            let mono = NSFont.monospacedSystemFont(
                ofSize: max(10, baseFont.pointSize - 1), weight: .regular
            )
            return [
                .font: mono,
                .backgroundColor: NSColor.quaternaryLabelColor
            ]
        })

        // 4. Expand placeholders back into styled code blocks.
        for b in blocks {
            let ns = attr.string as NSString
            let r = ns.range(of: b.token)
            guard r.location != NSNotFound else { continue }
            let rendered = renderCodeBlock(lang: b.lang, code: b.code, baseFont: baseFont)
            attr.replaceCharacters(in: r, with: rendered)
        }

        return attr
    }

    // MARK: - Code blocks

    private static func renderCodeBlock(
        lang: String, code: String, baseFont: NSFont
    ) -> NSAttributedString {
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

        // Optional language label line (above the block).
        if !lang.isEmpty {
            let labelPara = NSMutableParagraphStyle()
            labelPara.paragraphSpacingBefore = 8
            labelPara.paragraphSpacing = 0
            result.append(NSAttributedString(
                string: lang.uppercased() + "\n",
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: max(9, baseFont.pointSize - 4), weight: .semibold
                    ),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: labelPara,
                    .kern: 0.5
                ]
            ))
        }

        // Code body. Use NSTextTable so the surface fills the full line width
        // rather than just hugging the glyphs.
        let codePara = NSMutableParagraphStyle()
        codePara.lineHeightMultiple = 1.25
        codePara.paragraphSpacing = 8
        codePara.paragraphSpacingBefore = lang.isEmpty ? 8 : 2

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

        // Trailing newline so following prose lands on its own paragraph.
        result.append(NSAttributedString(
            string: "\n",
            attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor
            ]
        ))

        return result
    }

    // MARK: - Helpers

    private static func apply(
        _ attr: NSMutableAttributedString,
        pattern: String,
        build: (NSTextCheckingResult) -> [NSAttributedString.Key: Any]
    ) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        // Iterate matches in reverse so earlier ranges aren't shifted by edits.
        let full = NSRange(attr.string.startIndex..., in: attr.string)
        let matches = re.matches(in: attr.string, options: [], range: full).reversed()
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
}
