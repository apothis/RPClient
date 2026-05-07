import AppKit

/// Build a vertically-scrolling tab body containing the supplied views,
/// stacked with `lg` gaps and `xl` outer padding. Each view is constrained
/// to a 480pt width — the prose readability sweet spot at 13pt body. The
/// stack is the scroll's documentView (per CastPane pattern) and the
/// scroll itself is pinned inside a wrapper view so NSTabView's
/// frame-sizing reaches the inner content. Without the wrapper, NSTabView
/// can't size a `translatesAutoresizingMaskIntoConstraints = false` root
/// scroll view — the body collapses to zero.
private func makeScrollingTab(fields: [NSView]) -> NSView {
    // Wrapper keeps `translatesAutoresizingMaskIntoConstraints = true` (the
    // default) so NSTabView's frame-set on tab activation actually sizes it.
    // With the flag flipped to false there's no intrinsic-content driver
    // and the body collapses to zero — matches the existing CastPane /
    // BranchesPane pattern.
    let wrapper = NSView()

    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    wrapper.addSubview(scroll)

    let stack = NSStackView(views: fields)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = DesignTokens.Spacing.lg
    stack.edgeInsets = NSEdgeInsets(
        top: DesignTokens.Spacing.xl,
        left: DesignTokens.Spacing.xl,
        bottom: DesignTokens.Spacing.xl,
        right: DesignTokens.Spacing.xl
    )
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = stack

    var constraints: [NSLayoutConstraint] = [
        scroll.topAnchor.constraint(equalTo: wrapper.topAnchor),
        scroll.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
        scroll.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        scroll.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),

        stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        // Width-pin the stack to the clip view so we never get horizontal
        // scrolling and the inner fields' fixed-width children don't pull
        // the stack wider than the viewport.
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ]
    for field in fields {
        constraints.append(field.widthAnchor.constraint(equalToConstant: 480))
    }
    NSLayoutConstraint.activate(constraints)
    return wrapper
}

// MARK: - DetailsTabViewController (§5.3c.2)

/// Details tab — RPClient-structured identity-and-appearance fields per §3.9.
/// Six fields: Age, Pronouns, Species, Orientation (single-line), then
/// Appearance and Mood (multi-line). All optional. Saved to
/// `extensions["rpclient/details"]` and auto-folded into a fenced
/// `[character_details]` block at the start of `description` on save.
final class DetailsTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void

    private let ageField: SingleLineFieldView
    private let pronounsField: SingleLineFieldView
    private let speciesField: SingleLineFieldView
    private let orientationField: SingleLineFieldView
    private let appearanceField: MultilineFieldView
    private let moodField: MultilineFieldView

    init(draft: CharacterDraft, onDirty: @escaping () -> Void) {
        self.draft = draft
        self.onDirty = onDirty
        // Resolution order:
        //   1. extensions["rpclient/details"] (RPClient-edited cards, source of truth)
        //   2. parse fence in description (cards from other tools, or hand-edited)
        //   3. empty
        // If extensions were absent but the fence was present, eagerly mirror
        // the parsed values back into extensions so a save without edits
        // doesn't strip the fence.
        var seed = CardDetails()
        if let fromExt = CardDetails.extractFrom(draft.character) {
            seed = fromExt
        } else if let fromFence = CardStructuredFence.parseDetails(in: draft.character.description) {
            seed = fromFence
            seed.applyTo(&draft.character)
        }
        let d = seed

        self.ageField = SingleLineFieldView(label: "Age", initialValue: d.age, placeholder: CardCreatorPlaceholders.detailsAge)
        self.pronounsField = SingleLineFieldView(label: "Pronouns", initialValue: d.pronouns, placeholder: CardCreatorPlaceholders.detailsPronouns)
        self.speciesField = SingleLineFieldView(label: "Species", initialValue: d.species, placeholder: CardCreatorPlaceholders.detailsSpecies)
        self.orientationField = SingleLineFieldView(label: "Orientation", initialValue: d.orientation, placeholder: CardCreatorPlaceholders.detailsOrientation)
        self.appearanceField = MultilineFieldView(
            label: "Appearance",
            initialValue: d.appearance,
            hint: "Height, build, hair, eyes, skin, clothing — what they look like.",
            placeholder: CardCreatorPlaceholders.detailsAppearance,
            minHeight: 80,
            maxHeight: 220
        )
        self.moodField = MultilineFieldView(
            label: "Mood",
            initialValue: d.mood,
            hint: "Default emotional state, baseline temperament. Distinct from Personality (behavior).",
            placeholder: CardCreatorPlaceholders.detailsMood,
            minHeight: 64,
            maxHeight: 180
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        ageField.onChange = { [weak self] _ in self?.commit() }
        pronounsField.onChange = { [weak self] _ in self?.commit() }
        speciesField.onChange = { [weak self] _ in self?.commit() }
        orientationField.onChange = { [weak self] _ in self?.commit() }
        appearanceField.onChange = { [weak self] _ in self?.commit() }
        moodField.onChange = { [weak self] _ in self?.commit() }

        // Two columns of single-line identity fields (compact at top), then
        // the two multi-line fields full-width below.
        let identityRow1 = NSStackView(views: [ageField, pronounsField])
        identityRow1.orientation = .horizontal
        identityRow1.alignment = .top
        identityRow1.spacing = DesignTokens.Spacing.md
        identityRow1.distribution = .fillEqually
        identityRow1.translatesAutoresizingMaskIntoConstraints = false

        let identityRow2 = NSStackView(views: [speciesField, orientationField])
        identityRow2.orientation = .horizontal
        identityRow2.alignment = .top
        identityRow2.spacing = DesignTokens.Spacing.md
        identityRow2.distribution = .fillEqually
        identityRow2.translatesAutoresizingMaskIntoConstraints = false

        self.view = makeScrollingTab(fields: [
            identityRow1, identityRow2, appearanceField, moodField,
        ])
    }

    private func commit() {
        let d = CardDetails(
            age: ageField.stringValue,
            pronouns: pronounsField.stringValue,
            species: speciesField.stringValue,
            orientation: orientationField.stringValue,
            appearance: appearanceField.stringValue,
            mood: moodField.stringValue
        )
        d.applyTo(&draft.character)
        draft.markDirty()
        onDirty()
    }
}

// MARK: - IntimacyTabViewController (§5.3c.2)

/// Intimacy tab — RPClient-structured NSFW-aware fields per §3.9. Six
/// multi-line fields: Body, Sensitivities, Scent, Turn-ons, Kinks,
/// Limits. All optional. Saved to `extensions["rpclient/intimacy"]` and
/// auto-folded into a fenced `[character_intimacy]` block in
/// `description` on save.
final class IntimacyTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void

    private let buildField: MultilineFieldView
    private let anatomyField: MultilineFieldView
    private let markingsField: MultilineFieldView
    private let sensitivitiesField: MultilineFieldView
    private let scentField: MultilineFieldView
    private let turnOnsField: MultilineFieldView
    private let kinksField: MultilineFieldView
    private let limitsField: MultilineFieldView

    init(draft: CharacterDraft, onDirty: @escaping () -> Void) {
        self.draft = draft
        self.onDirty = onDirty
        // Same resolution + eager-mirror as DetailsTab.
        var seed = CardIntimacy()
        if let fromExt = CardIntimacy.extractFrom(draft.character) {
            seed = fromExt
        } else if let fromFence = CardStructuredFence.parseIntimacy(in: draft.character.description) {
            seed = fromFence
            seed.applyTo(&draft.character)
        }
        let i = seed

        self.buildField = MultilineFieldView(
            label: "Build",
            initialValue: i.build,
            hint: "Overall shape, height, weight, body type, athleticism.",
            placeholder: CardCreatorPlaceholders.intimacyBuild,
            minHeight: 64, maxHeight: 160
        )
        self.anatomyField = MultilineFieldView(
            label: "Anatomy",
            initialValue: i.anatomy,
            hint: "Explicit physical / sexual anatomy — chest, genitals, hips, sensitive areas.",
            placeholder: CardCreatorPlaceholders.intimacyAnatomy,
            minHeight: 80, maxHeight: 200
        )
        self.markingsField = MultilineFieldView(
            label: "Markings",
            initialValue: i.markings,
            hint: "Tattoos, scars, piercings, distinguishing features.",
            placeholder: CardCreatorPlaceholders.intimacyMarkings,
            minHeight: 64, maxHeight: 160
        )
        self.sensitivitiesField = MultilineFieldView(
            label: "Sensitivities",
            initialValue: i.sensitivities,
            hint: "Where they're ticklish, what arouses, neural-hot spots.",
            placeholder: CardCreatorPlaceholders.intimacySensitivities,
            minHeight: 64, maxHeight: 160
        )
        self.scentField = MultilineFieldView(
            label: "Scent",
            initialValue: i.scent,
            hint: "What they smell like; scent associations.",
            placeholder: CardCreatorPlaceholders.intimacyScent,
            minHeight: 64, maxHeight: 140
        )
        self.turnOnsField = MultilineFieldView(
            label: "Turn-ons",
            initialValue: i.turnOns,
            hint: "What arouses them. Often list-style.",
            placeholder: CardCreatorPlaceholders.intimacyTurnOns,
            minHeight: 80, maxHeight: 200
        )
        self.kinksField = MultilineFieldView(
            label: "Kinks",
            initialValue: i.kinks,
            hint: "Specific fetishes / preferences. Distinct from broader Turn-ons.",
            placeholder: CardCreatorPlaceholders.intimacyKinks,
            minHeight: 80, maxHeight: 200
        )
        self.limitsField = MultilineFieldView(
            label: "Limits",
            initialValue: i.limits,
            hint: "Hard nos, dislikes. AI-assist deliberately doesn't infer these — author intent.",
            placeholder: CardCreatorPlaceholders.intimacyLimits,
            minHeight: 64, maxHeight: 160
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        buildField.onChange = { [weak self] _ in self?.commit() }
        anatomyField.onChange = { [weak self] _ in self?.commit() }
        markingsField.onChange = { [weak self] _ in self?.commit() }
        sensitivitiesField.onChange = { [weak self] _ in self?.commit() }
        scentField.onChange = { [weak self] _ in self?.commit() }
        turnOnsField.onChange = { [weak self] _ in self?.commit() }
        kinksField.onChange = { [weak self] _ in self?.commit() }
        limitsField.onChange = { [weak self] _ in self?.commit() }

        self.view = makeScrollingTab(fields: [
            buildField, anatomyField, markingsField, sensitivitiesField,
            scentField, turnOnsField, kinksField, limitsField,
        ])
    }

    private func commit() {
        let i = CardIntimacy(
            build: buildField.stringValue,
            anatomy: anatomyField.stringValue,
            markings: markingsField.stringValue,
            sensitivities: sensitivitiesField.stringValue,
            scent: scentField.stringValue,
            turnOns: turnOnsField.stringValue,
            kinks: kinksField.stringValue,
            limits: limitsField.stringValue
        )
        i.applyTo(&draft.character)
        draft.markDirty()
        onDirty()
    }
}

// MARK: - PersonaTabViewController (§5.3b)

/// Persona tab — description / personality / scenario. Three multi-line
/// fields stacked vertically with `lg` gaps. Each field auto-grows up to
/// 320pt before scrolling.
final class PersonaTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void
    private let descriptionField: MultilineFieldView
    private let personalityField: MultilineFieldView
    private let scenarioField: MultilineFieldView

    init(draft: CharacterDraft, onDirty: @escaping () -> Void) {
        self.draft = draft
        self.onDirty = onDirty
        self.descriptionField = MultilineFieldView(
            label: "Description",
            initialValue: draft.character.description,
            hint: "Background, role, hooks. Reaches the prompt as part of the read-only memory prefix.",
            placeholder: CardCreatorPlaceholders.personaDescription
        )
        self.personalityField = MultilineFieldView(
            label: "Personality",
            initialValue: draft.character.personality,
            hint: "Disposition, tone, mannerisms. Often a list of traits.",
            placeholder: CardCreatorPlaceholders.personaPersonality
        )
        self.scenarioField = MultilineFieldView(
            label: "Scenario",
            initialValue: draft.character.scenario,
            hint: "The setting at the moment the chat begins. {{user}} expands to the active persona.",
            placeholder: CardCreatorPlaceholders.personaScenario
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        descriptionField.onChange = { [weak self] s in
            self?.draft.character.description = s
            self?.draft.markDirty()
            self?.onDirty()
        }
        personalityField.onChange = { [weak self] s in
            self?.draft.character.personality = s
            self?.draft.markDirty()
            self?.onDirty()
        }
        scenarioField.onChange = { [weak self] s in
            self?.draft.character.scenario = s
            self?.draft.markDirty()
            self?.onDirty()
        }

        self.view = makeScrollingTab(fields: [
            descriptionField, personalityField, scenarioField,
        ])
    }
}

// MARK: - GreetingsTabViewController (§5.3b)

/// Greetings tab — firstMessage (multi-line field) + alternateGreetings
/// (list editor) + groupOnlyGreetings (list editor, v3).
final class GreetingsTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void
    private let firstMessageField: MultilineFieldView
    private let alternateGreetingsEditor: GreetingListEditor
    private let groupOnlyEditor: GreetingListEditor

    init(draft: CharacterDraft, onDirty: @escaping () -> Void) {
        self.draft = draft
        self.onDirty = onDirty
        self.firstMessageField = MultilineFieldView(
            label: "First message",
            initialValue: draft.character.firstMessage,
            hint: "The character's opening line. Seeded as turn 0 when a new chat is created.",
            placeholder: CardCreatorPlaceholders.greetingsFirstMessage
        )
        self.alternateGreetingsEditor = GreetingListEditor(
            label: "Alternate greetings",
            initialValues: draft.character.alternateGreetings,
            hint: "Additional opening lines exposed as swipeable variants on turn 0."
        )
        self.groupOnlyEditor = GreetingListEditor(
            label: "Group-only greetings",
            initialValues: draft.character.groupOnlyGreetings,
            hint: "Greetings used only when the character joins a multi-cast group chat. v3 export only.",
            v3Only: true
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        firstMessageField.onChange = { [weak self] s in
            self?.draft.character.firstMessage = s
            self?.draft.markDirty()
            self?.onDirty()
        }
        alternateGreetingsEditor.onChange = { [weak self] arr in
            self?.draft.character.alternateGreetings = arr
            self?.draft.markDirty()
            self?.onDirty()
        }
        groupOnlyEditor.onChange = { [weak self] arr in
            self?.draft.character.groupOnlyGreetings = arr
            self?.draft.markDirty()
            self?.onDirty()
        }

        self.view = makeScrollingTab(fields: [
            firstMessageField, alternateGreetingsEditor, groupOnlyEditor,
        ])
    }
}

// MARK: - ExamplesTabViewController (§5.3b + §3.5)

/// Examples tab — messageExample multi-line field, plus the conditional
/// §3.5 "Restore example dialogue" affordance. The affordance is visible
/// only when `messageExample` is empty AND `description` contains the
/// legacy v1-squash separator.
final class ExamplesTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void
    private let exampleField: MultilineFieldView
    private let restoreCallout = NSStackView()
    private let restoreInfoLabel = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private var restoreVisibleConstraint: NSLayoutConstraint!
    private var dismissed = false

    init(draft: CharacterDraft, onDirty: @escaping () -> Void) {
        self.draft = draft
        self.onDirty = onDirty
        self.exampleField = MultilineFieldView(
            label: "Example dialogue",
            initialValue: draft.character.messageExample,
            hint: "Few-shot example exchanges. Helps the model match the character's voice.",
            placeholder: CardCreatorPlaceholders.exampleDialogue
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        exampleField.onChange = { [weak self] s in
            self?.draft.character.messageExample = s
            self?.draft.markDirty()
            self?.onDirty()
            self?.refreshRestoreVisibility()
        }

        // Restore-affordance row — built once and toggled visible.
        restoreInfoLabel.stringValue = "This card may have its example dialogue squashed into Description (legacy v1 import shape)."
        restoreInfoLabel.font = DesignTokens.Typography.subheadline
        restoreInfoLabel.textColor = DesignTokens.Foreground.secondary
        restoreInfoLabel.lineBreakMode = .byWordWrapping
        restoreInfoLabel.maximumNumberOfLines = 3
        restoreInfoLabel.translatesAutoresizingMaskIntoConstraints = false

        restoreButton.target = self
        restoreButton.action = #selector(restoreClicked)
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .small
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [restoreButton, dismissButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = DesignTokens.Spacing.sm
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        restoreCallout.orientation = .vertical
        restoreCallout.alignment = .leading
        restoreCallout.spacing = DesignTokens.Spacing.sm
        restoreCallout.translatesAutoresizingMaskIntoConstraints = false
        restoreCallout.addArrangedSubview(restoreInfoLabel)
        restoreCallout.addArrangedSubview(buttonRow)
        restoreCallout.isHidden = true

        self.view = makeScrollingTab(fields: [exampleField, restoreCallout])
        refreshRestoreVisibility()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-check visibility on every tab activation — the description
        // that gates the §3.5 affordance is edited on a different tab
        // (Persona), so the Examples tab can't rely on its own onChange.
        refreshRestoreVisibility()
    }

    private func refreshRestoreVisibility() {
        let shouldShow = !dismissed
            && draft.character.messageExample.isEmpty
            && CharacterCardImporter.containsLegacyExamplePrefix(draft.character.description)
        restoreCallout.isHidden = !shouldShow
    }

    @objc private func restoreClicked() {
        guard let split = CharacterCardImporter.splitLegacyExampleSquash(draft.character.description) else {
            return
        }
        draft.character.description = split.description
        draft.character.messageExample = split.messageExample
        exampleField.stringValue = split.messageExample
        draft.markDirty()
        onDirty()
        refreshRestoreVisibility()
        DebugLog.shared.write("cardcreator: restored example dialogue from legacy squash (\(split.messageExample.count)c)")
    }

    @objc private func dismissClicked() {
        dismissed = true
        refreshRestoreVisibility()
    }
}

// MARK: - SystemTabViewController (§5.3b)

/// System tab — systemPrompt / postHistoryInstructions / DepthPromptControl
/// / creatorNotes. Per V2_PHASE9_CARD_CREATOR §3.4, depth_prompt is
/// surfaced as a first-class control even though the engine integration
/// is out of §5.2 scope (round-trip preservation only).
final class SystemTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void
    private let systemPromptField: MultilineFieldView
    private let postHistoryField: MultilineFieldView
    private let depthPromptControl: DepthPromptControl
    private let creatorNotesField: MultilineFieldView

    init(draft: CharacterDraft, onDirty: @escaping () -> Void) {
        self.draft = draft
        self.onDirty = onDirty
        self.systemPromptField = MultilineFieldView(
            label: "System prompt",
            initialValue: draft.character.systemPrompt ?? "",
            hint: "Replaces the user's default system prompt. Use {{original}} to layer instead of replace.",
            placeholder: CardCreatorPlaceholders.systemPrompt
        )
        self.postHistoryField = MultilineFieldView(
            label: "Post-history instructions",
            initialValue: draft.character.postHistoryInstructions ?? "",
            hint: "Injected after history, near the response. Often used for tone or content-permission framing.",
            placeholder: CardCreatorPlaceholders.postHistoryInstructions
        )
        let extracted = DepthPrompt.extractFrom(draft.character)
        self.depthPromptControl = DepthPromptControl(initial: extracted)
        self.creatorNotesField = MultilineFieldView(
            label: "Creator notes",
            initialValue: draft.character.creatorNotes ?? "",
            hint: "Display only — never reaches the prompt. Trigger warnings, kink list, content rating.",
            placeholder: CardCreatorPlaceholders.creatorNotes
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        systemPromptField.onChange = { [weak self] s in
            self?.draft.character.systemPrompt = s.isEmpty ? nil : s
            self?.draft.markDirty()
            self?.onDirty()
        }
        postHistoryField.onChange = { [weak self] s in
            self?.draft.character.postHistoryInstructions = s.isEmpty ? nil : s
            self?.draft.markDirty()
            self?.onDirty()
        }
        creatorNotesField.onChange = { [weak self] s in
            self?.draft.character.creatorNotes = s.isEmpty ? nil : s
            self?.draft.markDirty()
            self?.onDirty()
        }
        depthPromptControl.onChange = { [weak self] dp in
            guard let self = self else { return }
            if let dp = dp, !dp.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dp.applyTo(&self.draft.character)
            } else {
                DepthPrompt.removeFrom(&self.draft.character)
            }
            self.draft.markDirty()
            self.onDirty()
        }

        self.view = makeScrollingTab(fields: [
            systemPromptField, postHistoryField, depthPromptControl, creatorNotesField,
        ])
    }
}

// MARK: - DepthPromptControl

/// First-class UI for the community `extensions["depth_prompt"]`
/// convention. Multi-line text input + depth stepper (mono numeric) +
/// role popup.
final class DepthPromptControl: NSView {

    /// Fires with the latest DepthPrompt or nil if the user emptied the
    /// prompt text. The owner decides whether to apply or remove from
    /// extensions.
    var onChange: ((DepthPrompt?) -> Void)?

    private let labelView = NSTextField(labelWithString: "Depth prompt")
    private let hintView = NSTextField(labelWithString: "Injected at a fixed depth near the response (community 'depth_prompt' convention). Round-trips through extensions for ST/Risu compatibility; engine integration is a follow-up.")
    private let promptField: MultilineFieldView
    private let depthStepper = NSStepper()
    private let depthValueLabel = NSTextField(labelWithString: "4")
    private let roleLabel = NSTextField(labelWithString: "Role")
    private let depthLabel = NSTextField(labelWithString: "Depth")
    private let rolePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private var depth: Int
    private var role: DepthPrompt.Role
    private var prompt: String

    init(initial: DepthPrompt?) {
        let dp = initial ?? DepthPrompt(prompt: "", depth: 4, role: .system)
        self.prompt = dp.prompt
        self.depth = dp.depth
        self.role = dp.role
        self.promptField = MultilineFieldView(
            label: "Prompt",
            initialValue: dp.prompt,
            hint: nil,
            minHeight: 64,
            maxHeight: 160
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false

        hintView.font = DesignTokens.Typography.subheadline
        hintView.textColor = DesignTokens.Foreground.secondary
        hintView.lineBreakMode = .byWordWrapping
        hintView.maximumNumberOfLines = 4
        hintView.translatesAutoresizingMaskIntoConstraints = false

        promptField.onChange = { [weak self] s in
            self?.prompt = s
            self?.notify()
        }

        // Depth controls — stepper + mono numeric label.
        depthLabel.font = DesignTokens.Typography.headline
        depthLabel.textColor = DesignTokens.Foreground.primary
        depthLabel.translatesAutoresizingMaskIntoConstraints = false

        depthStepper.minValue = 0
        depthStepper.maxValue = 10
        depthStepper.integerValue = depth
        depthStepper.target = self
        depthStepper.action = #selector(depthChanged)
        depthStepper.translatesAutoresizingMaskIntoConstraints = false

        depthValueLabel.font = DesignTokens.Typography.mono(.body)
        depthValueLabel.textColor = DesignTokens.Foreground.primary
        depthValueLabel.alignment = .right
        depthValueLabel.stringValue = String(depth)
        depthValueLabel.translatesAutoresizingMaskIntoConstraints = false

        let depthRow = NSStackView(views: [depthLabel, depthValueLabel, depthStepper])
        depthRow.orientation = .horizontal
        depthRow.alignment = .firstBaseline
        depthRow.spacing = DesignTokens.Spacing.sm
        depthRow.translatesAutoresizingMaskIntoConstraints = false

        // Role popup.
        roleLabel.font = DesignTokens.Typography.headline
        roleLabel.textColor = DesignTokens.Foreground.primary
        roleLabel.translatesAutoresizingMaskIntoConstraints = false

        rolePopup.translatesAutoresizingMaskIntoConstraints = false
        rolePopup.bezelStyle = .rounded
        rolePopup.controlSize = .small
        rolePopup.addItem(withTitle: "system")
        rolePopup.addItem(withTitle: "user")
        rolePopup.selectItem(withTitle: role.rawValue)
        rolePopup.target = self
        rolePopup.action = #selector(roleChanged)

        let roleRow = NSStackView(views: [roleLabel, rolePopup])
        roleRow.orientation = .horizontal
        roleRow.alignment = .firstBaseline
        roleRow.spacing = DesignTokens.Spacing.sm
        roleRow.translatesAutoresizingMaskIntoConstraints = false

        let configRow = NSStackView(views: [depthRow, roleRow])
        configRow.orientation = .horizontal
        configRow.spacing = DesignTokens.Spacing.lg
        configRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [labelView, hintView, promptField, configRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            promptField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            depthValueLabel.widthAnchor.constraint(equalToConstant: 24),
        ])
    }

    @objc private func depthChanged() {
        depth = depthStepper.integerValue
        depthValueLabel.stringValue = String(depth)
        notify()
    }

    @objc private func roleChanged() {
        guard let s = rolePopup.titleOfSelectedItem,
              let r = DepthPrompt.Role(rawValue: s) else { return }
        role = r
        notify()
    }

    private func notify() {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onChange?(nil)
        } else {
            onChange?(DepthPrompt(prompt: prompt, depth: depth, role: role))
        }
    }
}
