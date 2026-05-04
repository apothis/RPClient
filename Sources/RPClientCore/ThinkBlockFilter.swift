import Foundation

/// Streaming filter that strips a leading `<think>…</think>` block from a
/// Qwen3 reply. Tokens arrive in arbitrary chunks (potentially splitting the
/// opening or closing tag mid-character), so the filter is a small state
/// machine that buffers until it can decide.
///
/// Used only when the active chat is Qwen *and* `Settings.qwenThinkingEnabled`
/// is true. With thinking off, an empty `<think></think>` pre-fill in the
/// prompt suppresses the trace and there is nothing to strip.
///
/// Behaviour summary:
///   - If the reply opens with optional whitespace then `<think>`, everything
///     up to and including `</think>` (plus any trailing newlines that pad
///     the reply) is dropped.
///   - If the reply does not open with `<think>` (model decided to skip the
///     trace, or thinking was suppressed elsewhere), the buffered content is
///     flushed verbatim and the filter becomes a passthrough.
///   - The filter operates on the *prefix* only — once the post-think reply
///     has started flowing, every subsequent chunk passes through unchanged.
struct ThinkBlockFilter {
    private enum State {
        case waiting   // haven't decided whether the reply opens with <think>
        case inside    // currently inside the think block
        case done      // past the close tag (or never had one) — passthrough
    }

    private var state: State = .waiting
    private var buf: String = ""
    /// Set when we transition to `.done` from inside a `<think>` block. The
    /// next chunk's leading whitespace is dropped so a `</think>` that lands
    /// at the very end of one chunk doesn't leave the *next* chunk's `\n\n`
    /// padding to leak through as if it were reply content.
    private var trimLeadingWhitespaceOnNextChunk: Bool = false

    /// True while the model is mid-`<think>` block. Drives the UI
    /// "thinking…" indicator. Stays false during `.waiting` (we don't yet
    /// know whether thinking is happening) and `.done` (it's over or never
    /// started).
    var isInsideThinkBlock: Bool { state == .inside }

    /// Feed the next streamed chunk in; returns the portion of *displayable
    /// reply text* that should be appended to `turn.text`. May be empty if
    /// the filter is still buffering.
    mutating func ingest(_ chunk: String) -> String {
        switch state {
        case .done:
            var out = chunk
            if trimLeadingWhitespaceOnNextChunk {
                let trimmed = out.drop(while: { $0.isWhitespace })
                if trimmed.count != out.count {
                    out = String(trimmed)
                }
                // Clear the flag once a non-whitespace char has arrived. If
                // this chunk was *all* whitespace, keep waiting for content.
                if !trimmed.isEmpty {
                    trimLeadingWhitespaceOnNextChunk = false
                }
            }
            return out

        case .inside:
            buf += chunk
            guard let r = buf.range(of: "</think>") else { return "" }
            let after = buf[r.upperBound...]
            buf = ""
            state = .done
            // Drop the trailing whitespace/newlines Qwen3 emits between
            // </think> and the actual reply, so the persisted text doesn't
            // start with a blank gap. If the close tag was the last thing in
            // this chunk, arm a flag so the same trim runs on the *next*
            // chunk's leading whitespace.
            let trimmed = after.drop(while: { $0.isWhitespace })
            if trimmed.isEmpty {
                trimLeadingWhitespaceOnNextChunk = true
                return ""
            }
            return String(trimmed)

        case .waiting:
            buf += chunk
            let leadingWS = buf.prefix(while: { $0.isWhitespace })
            let body = buf[leadingWS.endIndex...]
            if body.hasPrefix("<think>") {
                let afterOpen = body.dropFirst("<think>".count)
                buf = String(afterOpen)
                state = .inside
                // Re-feed the residue through the inside-state branch so a
                // close tag already in the buffer (rare but possible) gets
                // resolved in the same call.
                return ingest("")
            }
            // Could the buffered body still grow into "<think>"? If so, keep
            // waiting; otherwise, flush and become a passthrough.
            if "<think>".hasPrefix(String(body)) {
                return ""
            }
            state = .done
            let out = buf
            buf = ""
            return out
        }
    }

    /// Called when the stream ends. Returns whatever was being held back —
    /// typically empty, but if the model produced an unterminated `<think>`
    /// block (broken output) we surface the residue rather than silently
    /// swallowing the entire reply.
    mutating func flush() -> String {
        switch state {
        case .done:
            return ""
        case .waiting:
            let out = buf
            buf = ""
            state = .done
            return out
        case .inside:
            // No close tag ever arrived. Nothing inside the think block is
            // meant to be displayed — surface a marker so the user sees the
            // reply was malformed rather than silently empty.
            buf = ""
            state = .done
            return "[unterminated <think> block — reply suppressed]"
        }
    }
}
