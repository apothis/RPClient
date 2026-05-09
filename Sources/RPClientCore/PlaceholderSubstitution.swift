import Foundation

// SillyTavern chara_card_v2 cards persist `{{char}}` and `{{user}}`
// as literal placeholder tokens; the chat runtime substitutes them
// before sending to the model.
//
// RPClient was missing this layer entirely (Phase 10 §10.c bug,
// surfaced when Emily was hallucinated as "Mia" — the model had no
// anchor for what the literal `{{char}}` referred to and picked a
// common name). This module owns substitution at every call site
// that hands card content to the model.
//
// Substitution is case-insensitive (`{{Char}}`, `{{CHAR}}` all
// resolve) — defensive against cards from other tools that don't
// stick to the lowercase canonical form. An empty `userName` falls
// back to "User" so persona-less chats with no Settings.userName
// don't emit grammatically broken sentences ("loves ." vs "User
// loves Emily.").
enum PlaceholderSubstitution {

    /// Substitute `{{char}}` and `{{user}}` in `text`. Empty
    /// `characterName` leaves `{{char}}` UNTOUCHED (better the model
    /// sees a literal token than a missing word — the original card
    /// state survives until a name is bound). Empty `userName`
    /// substitutes to "User" since most cards reference the user
    /// in narrative prose where a missing token breaks grammar.
    static func apply(_ text: String, characterName: String, userName: String) -> String {
        let trimmedChar = characterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userValue = trimmedUser.isEmpty ? "User" : trimmedUser

        var out = text
        // {{user}} always substitutes (never empty by the rule above).
        out = out.replacingOccurrences(of: "{{user}}", with: userValue, options: .caseInsensitive)
        // {{char}} only when we have a name to substitute IN; otherwise
        // leave the placeholder so the model at least sees the token
        // rather than a vacuum where a name should be.
        if !trimmedChar.isEmpty {
            out = out.replacingOccurrences(of: "{{char}}", with: trimmedChar, options: .caseInsensitive)
        }
        return out
    }
}
