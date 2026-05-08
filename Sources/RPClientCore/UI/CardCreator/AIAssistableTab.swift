import Foundation

/// Phase 9 §5.4.b — surface the (CardField, MultilineFieldView) pairs
/// each tab owns so the parent `CardCreatorViewController` can:
/// - dispatch Mode-2 proposals into the right field receiver (via
///   `MultilineFieldView.showProposal(text:refusal:)`),
/// - count fields-in-proposed-state for the bulk-action banner,
/// - bulk Accept-all / Reject-all by iterating across tabs.
///
/// Tabs without multi-line fields (Lorebook, Advanced) simply don't
/// conform.
@MainActor
protocol AIAssistableTab: AnyObject {
    var aiAssistableFields: [(CardField, MultilineFieldView)] { get }
}
