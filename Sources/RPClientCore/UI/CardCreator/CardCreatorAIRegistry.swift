import Foundation

/// Phase 9 §5.4.a — per-window registry that owns one
/// `CardSuggestionsController` per `CardField` and routes stale-on-edit
/// propagation across tabs.
///
/// One registry per `CharacterDraft` (per creator window). Tabs ask
/// for controllers by field name; the registry lazy-creates and
/// caches. When a field's value changes, the owning tab calls
/// `markDownstreamStale(of:)` and every controller whose
/// `CardFieldDependencies.upstreams(...)` lists the changed field
/// gets `markStale()` called on it — so an edit to `description`
/// surfaces a yellow "stale" badge on the personality / scenario /
/// first_message strips even though they live on a different tab.
@MainActor
final class CardCreatorAIRegistry {
    private let draft: CharacterDraft
    private var controllers: [CardField: CardSuggestionsController] = [:]

    init(draft: CharacterDraft) {
        self.draft = draft
    }

    /// Lazy lookup. Same field → same controller for the lifetime of
    /// the registry; subsequent calls return the existing instance.
    func controller(for field: CardField) -> CardSuggestionsController {
        if let existing = controllers[field] { return existing }
        let new = CardCreatorAIWiring.makeController(field: field, draft: draft)
        controllers[field] = new
        return new
    }

    /// Notify the registry that the given field's value was edited.
    /// Marks every downstream controller stale (per the §4.2 dep
    /// graph). Pass `.tags` (or rely on `markTagsChanged()`) when the
    /// tag list itself changed; same propagation, different upstream
    /// shape.
    func markDownstreamStale(of changedField: CardField) {
        DebugLog.shared.write("cardgen: registry markDownstreamStale(of: \(changedField.rawValue))")
        for (target, ctrl) in controllers {
            if target == changedField { continue }
            let upstreams = CardFieldDependencies.upstreams(for: target)
            let affects = upstreams.contains(.field(changedField))
            if affects {
                ctrl.markStale()
            }
        }
    }

    /// Tags is special — it isn't a `CardField` itself but appears as
    /// an upstream for almost every narrative-shaped field.
    func markTagsChanged() {
        DebugLog.shared.write("cardgen: registry markTagsChanged")
        for (_, ctrl) in controllers {
            // Every controller whose field has `.tags` in its upstream
            // list. Cheap to compute every time.
            let upstreams = CardFieldDependencies.upstreams(for: ctrl.field)
            if upstreams.contains(.tags) {
                ctrl.markStale()
            }
        }
    }
}
