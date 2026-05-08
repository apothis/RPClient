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
    private let aiRegistry: CardCreatorAIRegistry

    init(draft: CharacterDraft, onDirty: @escaping () -> Void, aiRegistry: CardCreatorAIRegistry) {
        self.draft = draft
        self.onDirty = onDirty
        self.aiRegistry = aiRegistry
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
            maxHeight: 220,
            hasSuggestionsStrip: true
        )
        self.moodField = MultilineFieldView(
            label: "Mood",
            initialValue: d.mood,
            hint: "Default emotional state, baseline temperament. Distinct from Personality (behavior).",
            placeholder: CardCreatorPlaceholders.detailsMood,
            minHeight: 64,
            maxHeight: 180,
            hasSuggestionsStrip: true
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        ageField.onChange = { [weak self] _ in
            self?.commit()
            self?.aiRegistry.markDownstreamStale(of: .detailsAge)
        }
        pronounsField.onChange = { [weak self] _ in
            self?.commit()
            self?.aiRegistry.markDownstreamStale(of: .detailsPronouns)
        }
        speciesField.onChange = { [weak self] _ in
            self?.commit()
            self?.aiRegistry.markDownstreamStale(of: .detailsSpecies)
        }
        orientationField.onChange = { [weak self] _ in
            self?.commit()
            self?.aiRegistry.markDownstreamStale(of: .detailsOrientation)
        }
        appearanceField.onChange = { [weak self] _ in
            self?.commit()
            self?.aiRegistry.markDownstreamStale(of: .detailsAppearance)
        }
        moodField.onChange = { [weak self] _ in
            self?.commit()
            self?.aiRegistry.markDownstreamStale(of: .detailsMood)
        }

        CardCreatorAIWiring.attachStrip(to: appearanceField, field: .detailsAppearance, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: moodField, field: .detailsMood, aiRegistry: aiRegistry, draft: draft)

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
        // Read-modify-write so we don't clobber the `sex` field
        // owned by the Identity tab (Phase 9 §5.4 sex chooser).
        var d = CardDetails.extractFrom(draft.character) ?? CardDetails()
        d.age = ageField.stringValue
        d.pronouns = pronounsField.stringValue
        d.species = speciesField.stringValue
        d.orientation = orientationField.stringValue
        d.appearance = appearanceField.stringValue
        d.mood = moodField.stringValue
        d.applyTo(&draft.character)
        draft.markDirty()
        onDirty()
    }
}

extension DetailsTabViewController: AIAssistableTab {
    var aiAssistableFields: [(CardField, MultilineFieldView)] {
        [
            (.detailsAppearance, appearanceField),
            (.detailsMood, moodField),
        ]
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
    private let aiRegistry: CardCreatorAIRegistry

    private let buildField: MultilineFieldView
    private let anatomyField: MultilineFieldView
    private let markingsField: MultilineFieldView
    private let sensitivitiesField: MultilineFieldView
    private let scentField: MultilineFieldView
    private let turnOnsField: MultilineFieldView
    private let kinksField: MultilineFieldView
    private let limitsField: MultilineFieldView

    init(draft: CharacterDraft, onDirty: @escaping () -> Void, aiRegistry: CardCreatorAIRegistry) {
        self.draft = draft
        self.onDirty = onDirty
        self.aiRegistry = aiRegistry
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
            minHeight: 64, maxHeight: 160,
            hasSuggestionsStrip: true
        )
        self.anatomyField = MultilineFieldView(
            label: "Anatomy",
            initialValue: i.anatomy,
            hint: "Explicit physical / sexual anatomy — chest, genitals, hips, sensitive areas.",
            placeholder: CardCreatorPlaceholders.intimacyAnatomy,
            minHeight: 80, maxHeight: 200,
            hasSuggestionsStrip: true
        )
        self.markingsField = MultilineFieldView(
            label: "Markings",
            initialValue: i.markings,
            hint: "Tattoos, scars, piercings, distinguishing features.",
            placeholder: CardCreatorPlaceholders.intimacyMarkings,
            minHeight: 64, maxHeight: 160,
            hasSuggestionsStrip: true
        )
        self.sensitivitiesField = MultilineFieldView(
            label: "Sensitivities",
            initialValue: i.sensitivities,
            hint: "Where they're ticklish, what arouses, neural-hot spots.",
            placeholder: CardCreatorPlaceholders.intimacySensitivities,
            minHeight: 64, maxHeight: 160,
            hasSuggestionsStrip: true
        )
        self.scentField = MultilineFieldView(
            label: "Scent",
            initialValue: i.scent,
            hint: "What they smell like; scent associations.",
            placeholder: CardCreatorPlaceholders.intimacyScent,
            minHeight: 64, maxHeight: 140,
            hasSuggestionsStrip: true
        )
        self.turnOnsField = MultilineFieldView(
            label: "Turn-ons",
            initialValue: i.turnOns,
            hint: "What arouses them. Often list-style.",
            placeholder: CardCreatorPlaceholders.intimacyTurnOns,
            minHeight: 80, maxHeight: 200,
            hasSuggestionsStrip: true
        )
        self.kinksField = MultilineFieldView(
            label: "Kinks",
            initialValue: i.kinks,
            hint: "Specific fetishes / preferences. Distinct from broader Turn-ons.",
            placeholder: CardCreatorPlaceholders.intimacyKinks,
            minHeight: 80, maxHeight: 200,
            hasSuggestionsStrip: true
        )
        self.limitsField = MultilineFieldView(
            label: "Limits",
            initialValue: i.limits,
            hint: "Hard nos, dislikes. AI-assist deliberately doesn't infer these — author intent.",
            placeholder: CardCreatorPlaceholders.intimacyLimits,
            minHeight: 64, maxHeight: 160,
            hasSuggestionsStrip: true
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        buildField.onChange = { [weak self] _ in
            self?.commit(); self?.aiRegistry.markDownstreamStale(of: .intimacyBuild)
        }
        anatomyField.onChange = { [weak self] _ in
            self?.commit(); self?.aiRegistry.markDownstreamStale(of: .intimacyAnatomy)
        }
        markingsField.onChange = { [weak self] _ in
            self?.commit(); self?.aiRegistry.markDownstreamStale(of: .intimacyMarkings)
        }
        sensitivitiesField.onChange = { [weak self] _ in
            self?.commit(); self?.aiRegistry.markDownstreamStale(of: .intimacySensitivities)
        }
        scentField.onChange = { [weak self] _ in
            self?.commit(); self?.aiRegistry.markDownstreamStale(of: .intimacyScent)
        }
        turnOnsField.onChange = { [weak self] _ in
            self?.commit(); self?.aiRegistry.markDownstreamStale(of: .intimacyTurnOns)
        }
        kinksField.onChange = { [weak self] _ in
            self?.commit(); self?.aiRegistry.markDownstreamStale(of: .intimacyKinks)
        }
        limitsField.onChange = { [weak self] _ in
            self?.commit(); self?.aiRegistry.markDownstreamStale(of: .intimacyLimits)
        }

        CardCreatorAIWiring.attachStrip(to: buildField, field: .intimacyBuild, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: anatomyField, field: .intimacyAnatomy, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: markingsField, field: .intimacyMarkings, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: sensitivitiesField, field: .intimacySensitivities, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: scentField, field: .intimacyScent, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: turnOnsField, field: .intimacyTurnOns, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: kinksField, field: .intimacyKinks, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: limitsField, field: .intimacyLimits, aiRegistry: aiRegistry, draft: draft)

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

extension IntimacyTabViewController: AIAssistableTab {
    var aiAssistableFields: [(CardField, MultilineFieldView)] {
        [
            (.intimacyBuild, buildField),
            (.intimacyAnatomy, anatomyField),
            (.intimacyMarkings, markingsField),
            (.intimacySensitivities, sensitivitiesField),
            (.intimacyScent, scentField),
            (.intimacyTurnOns, turnOnsField),
            (.intimacyKinks, kinksField),
            (.intimacyLimits, limitsField),
        ]
    }
}

// MARK: - PersonaTabViewController (§5.3b)

/// Persona tab — description / personality / scenario. Three multi-line
/// fields stacked vertically with `lg` gaps. Each field auto-grows up to
/// 320pt before scrolling.
final class PersonaTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void
    private let aiRegistry: CardCreatorAIRegistry
    private let descriptionField: MultilineFieldView
    private let personalityField: MultilineFieldView
    private let scenarioField: MultilineFieldView

    init(draft: CharacterDraft, onDirty: @escaping () -> Void, aiRegistry: CardCreatorAIRegistry) {
        self.draft = draft
        self.onDirty = onDirty
        self.aiRegistry = aiRegistry
        self.descriptionField = MultilineFieldView(
            label: "Description",
            initialValue: draft.character.description,
            hint: "Background, role, hooks. Reaches the prompt as part of the read-only memory prefix.",
            placeholder: CardCreatorPlaceholders.personaDescription,
            hasSuggestionsStrip: true
        )
        self.personalityField = MultilineFieldView(
            label: "Personality",
            initialValue: draft.character.personality,
            hint: "Disposition, tone, mannerisms. Often a list of traits.",
            placeholder: CardCreatorPlaceholders.personaPersonality,
            hasSuggestionsStrip: true
        )
        self.scenarioField = MultilineFieldView(
            label: "Scenario",
            initialValue: draft.character.scenario,
            hint: "The setting at the moment the chat begins. {{user}} expands to the active persona.",
            placeholder: CardCreatorPlaceholders.personaScenario,
            hasSuggestionsStrip: true
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        descriptionField.onChange = { [weak self] s in
            self?.draft.character.description = s
            self?.draft.markDirty()
            self?.onDirty()
            self?.aiRegistry.markDownstreamStale(of: .description)
        }
        personalityField.onChange = { [weak self] s in
            self?.draft.character.personality = s
            self?.draft.markDirty()
            self?.onDirty()
            self?.aiRegistry.markDownstreamStale(of: .personality)
        }
        scenarioField.onChange = { [weak self] s in
            self?.draft.character.scenario = s
            self?.draft.markDirty()
            self?.onDirty()
            self?.aiRegistry.markDownstreamStale(of: .scenario)
        }

        CardCreatorAIWiring.attachStrip(to: descriptionField, field: .description, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: personalityField, field: .personality, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: scenarioField, field: .scenario, aiRegistry: aiRegistry, draft: draft)

        self.view = makeScrollingTab(fields: [
            descriptionField, personalityField, scenarioField,
        ])
    }
}

extension PersonaTabViewController: AIAssistableTab {
    var aiAssistableFields: [(CardField, MultilineFieldView)] {
        [
            (.description, descriptionField),
            (.personality, personalityField),
            (.scenario, scenarioField),
        ]
    }
}

// MARK: - GreetingsTabViewController (§5.3b)

/// Greetings tab — firstMessage (multi-line field) + alternateGreetings
/// (list editor) + groupOnlyGreetings (list editor, v3).
final class GreetingsTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void
    private let aiRegistry: CardCreatorAIRegistry
    private let firstMessageField: MultilineFieldView
    private let alternateGreetingsEditor: GreetingListEditor
    private let groupOnlyEditor: GreetingListEditor

    init(draft: CharacterDraft, onDirty: @escaping () -> Void, aiRegistry: CardCreatorAIRegistry) {
        self.draft = draft
        self.onDirty = onDirty
        self.aiRegistry = aiRegistry
        self.firstMessageField = MultilineFieldView(
            label: "First message",
            initialValue: draft.character.firstMessage,
            hint: "The character's opening line. Seeded as turn 0 when a new chat is created.",
            placeholder: CardCreatorPlaceholders.greetingsFirstMessage,
            hasSuggestionsStrip: true
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
            self?.aiRegistry.markDownstreamStale(of: .firstMessage)
        }
        alternateGreetingsEditor.onChange = { [weak self] arr in
            self?.draft.character.alternateGreetings = arr
            self?.draft.markDirty()
            self?.onDirty()
        }
        alternateGreetingsEditor.onGenerate = { [weak self] completion in
            guard let self else { completion(nil); return }
            CardCreatorAIWiring.generateOnce(
                field: .alternateGreetings, draft: self.draft, completion: completion
            )
        }
        groupOnlyEditor.onChange = { [weak self] arr in
            self?.draft.character.groupOnlyGreetings = arr
            self?.draft.markDirty()
            self?.onDirty()
        }
        groupOnlyEditor.onGenerate = { [weak self] completion in
            guard let self else { completion(nil); return }
            CardCreatorAIWiring.generateOnce(
                field: .groupOnlyGreetings, draft: self.draft, completion: completion
            )
        }

        CardCreatorAIWiring.attachStrip(to: firstMessageField, field: .firstMessage, aiRegistry: aiRegistry, draft: draft)

        self.view = makeScrollingTab(fields: [
            firstMessageField, alternateGreetingsEditor, groupOnlyEditor,
        ])
    }
}

extension GreetingsTabViewController: AIAssistableTab {
    var aiAssistableFields: [(CardField, MultilineFieldView)] {
        [(.firstMessage, firstMessageField)]
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
    private let aiRegistry: CardCreatorAIRegistry
    private let exampleField: MultilineFieldView
    private let restoreCallout = NSStackView()
    private let restoreInfoLabel = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private var restoreVisibleConstraint: NSLayoutConstraint!
    private var dismissed = false

    init(draft: CharacterDraft, onDirty: @escaping () -> Void, aiRegistry: CardCreatorAIRegistry) {
        self.draft = draft
        self.onDirty = onDirty
        self.aiRegistry = aiRegistry
        self.exampleField = MultilineFieldView(
            label: "Example dialogue",
            initialValue: draft.character.messageExample,
            hint: "Few-shot example exchanges. Helps the model match the character's voice.",
            placeholder: CardCreatorPlaceholders.exampleDialogue,
            hasSuggestionsStrip: true
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
            self?.aiRegistry.markDownstreamStale(of: .messageExample)
        }
        CardCreatorAIWiring.attachStrip(to: exampleField, field: .messageExample, aiRegistry: aiRegistry, draft: draft)

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

extension ExamplesTabViewController: AIAssistableTab {
    var aiAssistableFields: [(CardField, MultilineFieldView)] {
        [(.messageExample, exampleField)]
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
    private let aiRegistry: CardCreatorAIRegistry
    private let systemPromptField: MultilineFieldView
    private let postHistoryField: MultilineFieldView
    private let depthPromptControl: DepthPromptControl
    private let creatorNotesField: MultilineFieldView

    init(draft: CharacterDraft, onDirty: @escaping () -> Void, aiRegistry: CardCreatorAIRegistry) {
        self.draft = draft
        self.onDirty = onDirty
        self.aiRegistry = aiRegistry
        self.systemPromptField = MultilineFieldView(
            label: "System prompt",
            initialValue: draft.character.systemPrompt ?? "",
            hint: "Replaces the user's default system prompt. Use {{original}} to layer instead of replace.",
            placeholder: CardCreatorPlaceholders.systemPrompt,
            hasSuggestionsStrip: true
        )
        self.postHistoryField = MultilineFieldView(
            label: "Post-history instructions",
            initialValue: draft.character.postHistoryInstructions ?? "",
            hint: "Injected after history, near the response. Often used for tone or content-permission framing.",
            placeholder: CardCreatorPlaceholders.postHistoryInstructions,
            hasSuggestionsStrip: true
        )
        let extracted = DepthPrompt.extractFrom(draft.character)
        self.depthPromptControl = DepthPromptControl(initial: extracted)
        self.creatorNotesField = MultilineFieldView(
            label: "Creator notes",
            initialValue: draft.character.creatorNotes ?? "",
            hint: "Display only — never reaches the prompt. Trigger warnings, kink list, content rating.",
            placeholder: CardCreatorPlaceholders.creatorNotes,
            hasSuggestionsStrip: true
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        systemPromptField.onChange = { [weak self] s in
            self?.draft.character.systemPrompt = s.isEmpty ? nil : s
            self?.draft.markDirty()
            self?.onDirty()
            self?.aiRegistry.markDownstreamStale(of: .systemPrompt)
        }
        postHistoryField.onChange = { [weak self] s in
            self?.draft.character.postHistoryInstructions = s.isEmpty ? nil : s
            self?.draft.markDirty()
            self?.onDirty()
            self?.aiRegistry.markDownstreamStale(of: .postHistoryInstructions)
        }
        creatorNotesField.onChange = { [weak self] s in
            self?.draft.character.creatorNotes = s.isEmpty ? nil : s
            self?.draft.markDirty()
            self?.onDirty()
            self?.aiRegistry.markDownstreamStale(of: .creatorNotes)
        }
        CardCreatorAIWiring.attachStrip(to: systemPromptField, field: .systemPrompt, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: postHistoryField, field: .postHistoryInstructions, aiRegistry: aiRegistry, draft: draft)
        CardCreatorAIWiring.attachStrip(to: creatorNotesField, field: .creatorNotes, aiRegistry: aiRegistry, draft: draft)
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

extension SystemTabViewController: AIAssistableTab {
    var aiAssistableFields: [(CardField, MultilineFieldView)] {
        [
            (.systemPrompt, systemPromptField),
            (.postHistoryInstructions, postHistoryField),
            (.creatorNotes, creatorNotesField),
        ]
    }
}

// MARK: - AdvancedTabViewController (§5.3c.4)

/// Advanced tab — v3-only `source` URLs/IDs, multilingual creator notes,
/// and a read-only `extensions` JSON viewer. Power-user surface; most
/// authors won't touch it.
final class AdvancedTabViewController: NSViewController {
    private let draft: CharacterDraft
    private let onDirty: () -> Void

    private let sourceEditor: StringListEditor
    private let multilingualEditor: MultilingualNotesEditor
    private let extensionsViewer = ExtensionsJSONViewer()

    init(draft: CharacterDraft, onDirty: @escaping () -> Void) {
        self.draft = draft
        self.onDirty = onDirty
        self.sourceEditor = StringListEditor(
            label: "Source",
            initialValues: draft.character.source,
            hint: "URLs or external IDs that point at where this card came from. v3 export only — readers append, never overwrite.",
            placeholder: "https://chub.ai/characters/foo/bar",
            v3Only: true
        )
        self.multilingualEditor = MultilingualNotesEditor(
            initialValues: draft.character.creatorNotesMultilingual ?? [:]
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        sourceEditor.onChange = { [weak self] arr in
            self?.draft.character.source = arr
            self?.draft.markDirty()
            self?.onDirty()
            self?.refreshExtensionsViewer()
        }
        multilingualEditor.onChange = { [weak self] dict in
            self?.draft.character.creatorNotesMultilingual = dict.isEmpty ? nil : dict
            self?.draft.markDirty()
            self?.onDirty()
            self?.refreshExtensionsViewer()
        }
        refreshExtensionsViewer()
        self.view = makeScrollingTab(fields: [
            sourceEditor, multilingualEditor, extensionsViewer,
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The other tabs mutate Character.extensions (depth_prompt,
        // rpclient/details, rpclient/intimacy). Re-render the JSON viewer
        // every time Advanced is shown so the dump matches reality.
        refreshExtensionsViewer()
    }

    private func refreshExtensionsViewer() {
        extensionsViewer.update(extensions: draft.character.extensions)
    }
}

// MARK: - StringListEditor (lighter sibling of GreetingListEditor)

/// Single-line list editor — used for `source` URLs. Each row is a single-
/// line text field rather than a multi-line text view. Hover-revealed
/// up/down/trash matching the GreetingListEditor pattern.
final class StringListEditor: NSView {

    var onChange: (([String]) -> Void)?

    private let label: String
    private let hint: String?
    private let placeholder: String
    private let v3Only: Bool

    private let labelView = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let addButton = NSButton(title: "+ Add", target: nil, action: nil)
    private let emptyState = NSTextField(labelWithString: "")

    private(set) var values: [String] = []

    init(label: String,
         initialValues: [String],
         hint: String? = nil,
         placeholder: String = "",
         v3Only: Bool = false) {
        self.label = label
        self.hint = hint
        self.placeholder = placeholder
        self.v3Only = v3Only
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(initialValues: initialValues)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(initialValues: [String]) {
        labelView.stringValue = label
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [labelView])
        header.orientation = .horizontal
        header.spacing = DesignTokens.Spacing.xs
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        if v3Only { header.addArrangedSubview(makeV3PillView()) }
        addSubview(header)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        emptyState.stringValue = "No entries. Click + Add to add one."
        emptyState.font = DesignTokens.Typography.subheadline
        emptyState.textColor = DesignTokens.Foreground.secondary
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)

        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        var hintConstraints: [NSLayoutConstraint] = []
        var topAnchorTarget: NSLayoutConstraint
        if let hintText = hint {
            let hintView = NSTextField(labelWithString: hintText)
            hintView.font = DesignTokens.Typography.subheadline
            hintView.textColor = DesignTokens.Foreground.secondary
            hintView.lineBreakMode = .byWordWrapping
            hintView.maximumNumberOfLines = 3
            hintView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hintView)
            hintConstraints = [
                hintView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.xs),
                hintView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hintView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ]
            topAnchorTarget = stack.topAnchor.constraint(equalTo: hintView.bottomAnchor, constant: DesignTokens.Spacing.sm)
        } else {
            topAnchorTarget = stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.sm)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            topAnchorTarget,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyState.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            emptyState.topAnchor.constraint(equalTo: stack.topAnchor),

            addButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: DesignTokens.Spacing.sm),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + hintConstraints)

        values = initialValues
        rebuildRows()
    }

    @objc private func addClicked() {
        values.append("")
        rebuildRows()
        onChange?(values)
        if let lastRow = stack.arrangedSubviews.last as? StringListRow {
            window?.makeFirstResponder(lastRow.field)
        }
    }

    fileprivate func updateRow(at index: Int, to text: String) {
        guard index >= 0 && index < values.count else { return }
        values[index] = text
        onChange?(values)
    }

    fileprivate func deleteRow(at index: Int) {
        guard index >= 0 && index < values.count else { return }
        values.remove(at: index)
        rebuildRows()
        onChange?(values)
    }

    private func rebuildRows() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        emptyState.isHidden = !values.isEmpty
        for (i, value) in values.enumerated() {
            let row = StringListRow(index: i, value: value, placeholder: placeholder, editor: self)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeV3PillView() -> NSView {
        let pill = NSTextField(labelWithString: "v3")
        pill.font = DesignTokens.Typography.caption2
        pill.textColor = DesignTokens.Foreground.secondary
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.drawsBackground = false
        let wrap = AppearanceAwareLayerView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.backgroundColor = DesignTokens.Background.group
        wrap.cornerRadiusValue = DesignTokens.Radius.chip
        wrap.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            pill.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            pill.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }
}

private final class StringListRow: NSView {

    let field = NSTextField()
    private let deleteButton = NSButton(title: "", target: nil, action: nil)
    private let index: Int
    private weak var editor: StringListEditor?

    init(index: Int, value: String, placeholder: String, editor: StringListEditor) {
        self.index = index
        self.editor = editor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(value: value, placeholder: placeholder)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(value: String, placeholder: String) {
        field.stringValue = value
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = DesignTokens.Typography.body
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")
        deleteButton.isBordered = false
        deleteButton.imagePosition = .imageOnly
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.contentTintColor = DesignTokens.Foreground.secondary
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.alphaValue = 0
        addSubview(field)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -DesignTokens.Spacing.xs),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),

            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        animateAlpha(to: 1)
    }

    override func mouseExited(with event: NSEvent) {
        animateAlpha(to: 0)
    }

    private func animateAlpha(to target: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.hoverFade
            ctx.allowsImplicitAnimation = true
            deleteButton.animator().alphaValue = target
        }
    }

    @objc private func deleteClicked() {
        editor?.deleteRow(at: index)
    }
}

extension StringListRow: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        editor?.updateRow(at: index, to: field.stringValue)
    }
}

// MARK: - MultilingualNotesEditor

/// Editor for `creatorNotesMultilingual: [String: String]?` — language-keyed
/// creator notes per the v3 spec. Each row is `lang-popup + text-area +
/// delete`. Add-row footer adds a new entry with a default lang of "en".
final class MultilingualNotesEditor: NSView {

    var onChange: (([String: String]) -> Void)?

    /// Common ISO 639-1 codes the v3 spec calls out — popup defaults
    /// authors to picking from this list. They can also type a custom 2-letter
    /// code via the popup's "Custom…" sentinel (deferred — for now they
    /// pick from this set; rare langs land in the JSON viewer's edit-on-
    /// disk follow-up).
    static let commonLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("ja", "Japanese"), ("ko", "Korean"),
        ("zh", "Chinese"), ("de", "German"), ("fr", "French"),
        ("es", "Spanish"), ("it", "Italian"), ("pt", "Portuguese"),
        ("ru", "Russian"), ("ar", "Arabic"), ("hi", "Hindi"),
    ]

    private var entries: [(lang: String, text: String)] = []

    private let labelView = NSTextField(labelWithString: "Creator notes (multilingual)")
    private let hintView = NSTextField(wrappingLabelWithString:
        "Per-language overrides for Creator notes. v3 export only. Reader picks the entry matching the user's locale; falls back to the plain Creator notes field on the System tab.")
    private let stack = NSStackView()
    private let addButton = NSButton(title: "+ Add language", target: nil, action: nil)
    private let v3Pill: NSView

    override init(frame frameRect: NSRect) {
        self.v3Pill = MultilingualNotesEditor.makeV3Pill()
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    convenience init(initialValues: [String: String]) {
        self.init(frame: .zero)
        self.entries = initialValues.map { (lang: $0.key, text: $0.value) }
            .sorted { $0.lang < $1.lang }
        rebuildRows()
    }

    private func buildUI() {
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [labelView, v3Pill])
        header.orientation = .horizontal
        header.spacing = DesignTokens.Spacing.xs
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        hintView.font = DesignTokens.Typography.subheadline
        hintView.textColor = DesignTokens.Foreground.secondary
        hintView.maximumNumberOfLines = 4
        hintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintView)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),

            hintView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.xs),
            hintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintView.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: hintView.bottomAnchor, constant: DesignTokens.Spacing.sm),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            addButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: DesignTokens.Spacing.sm),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func addClicked() {
        // Default new entries to "en" unless that's already taken.
        let usedLangs = Set(entries.map { $0.lang })
        let nextLang = MultilingualNotesEditor.commonLanguages
            .first(where: { !usedLangs.contains($0.code) })?.code ?? "en"
        entries.append((lang: nextLang, text: ""))
        rebuildRows()
        notify()
    }

    fileprivate func updateRow(at index: Int, lang: String, text: String) {
        guard index >= 0 && index < entries.count else { return }
        entries[index] = (lang: lang, text: text)
        notify()
    }

    fileprivate func deleteRow(at index: Int) {
        guard index >= 0 && index < entries.count else { return }
        entries.remove(at: index)
        rebuildRows()
        notify()
    }

    private func rebuildRows() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (i, entry) in entries.enumerated() {
            let row = MultilingualNotesRow(index: i, lang: entry.lang, text: entry.text, editor: self)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func notify() {
        var dict: [String: String] = [:]
        for entry in entries where !entry.lang.isEmpty {
            // Last write wins on duplicate-lang rows — UI doesn't prevent
            // it but the storage shape is a dict.
            dict[entry.lang] = entry.text
        }
        onChange?(dict)
    }

    private static func makeV3Pill() -> NSView {
        let pill = NSTextField(labelWithString: "v3")
        pill.font = DesignTokens.Typography.caption2
        pill.textColor = DesignTokens.Foreground.secondary
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.drawsBackground = false
        let wrap = AppearanceAwareLayerView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.backgroundColor = DesignTokens.Background.group
        wrap.cornerRadiusValue = DesignTokens.Radius.chip
        wrap.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            pill.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            pill.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }
}

private final class MultilingualNotesRow: NSView {

    private let langPopup = NSPopUpButton()
    private let textView = PlaceholderTextView()
    private let scroll = NSScrollView()
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    private let index: Int
    private weak var editor: MultilingualNotesEditor?

    init(index: Int, lang: String, text: String, editor: MultilingualNotesEditor) {
        self.index = index
        self.editor = editor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(lang: lang, text: text)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(lang: String, text: String) {
        langPopup.translatesAutoresizingMaskIntoConstraints = false
        langPopup.bezelStyle = .rounded
        langPopup.controlSize = .small
        for entry in MultilingualNotesEditor.commonLanguages {
            let item = NSMenuItem(title: "\(entry.code) — \(entry.name)", action: nil, keyEquivalent: "")
            item.representedObject = entry.code
            langPopup.menu?.addItem(item)
        }
        // Select the matching language. If the existing lang isn't in our
        // common set, append it so it survives a save without forcing the
        // user to remap.
        if !MultilingualNotesEditor.commonLanguages.contains(where: { $0.code == lang }) {
            let item = NSMenuItem(title: "\(lang)", action: nil, keyEquivalent: "")
            item.representedObject = lang
            langPopup.menu?.addItem(item)
        }
        if let idx = langPopup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == lang }) {
            langPopup.selectItem(at: idx)
        }
        langPopup.target = self
        langPopup.action = #selector(langChanged)
        addSubview(langPopup)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = DesignTokens.Typography.body
        textView.textColor = DesignTokens.Foreground.primary
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.string = text
        textView.delegate = self
        textView.placeholderString = "Notes in this language…"
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scroll.documentView = textView
        addSubview(scroll)

        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")
        deleteButton.isBordered = false
        deleteButton.imagePosition = .imageOnly
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.contentTintColor = DesignTokens.Foreground.secondary
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            langPopup.topAnchor.constraint(equalTo: topAnchor),
            langPopup.leadingAnchor.constraint(equalTo: leadingAnchor),
            langPopup.widthAnchor.constraint(equalToConstant: 140),

            deleteButton.topAnchor.constraint(equalTo: topAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),

            scroll.topAnchor.constraint(equalTo: langPopup.bottomAnchor, constant: DesignTokens.Spacing.xs),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 80),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func langChanged() {
        emit()
    }

    @objc private func deleteClicked() {
        editor?.deleteRow(at: index)
    }

    private func emit() {
        let lang = (langPopup.selectedItem?.representedObject as? String) ?? "en"
        editor?.updateRow(at: index, lang: lang, text: textView.string)
    }
}

extension MultilingualNotesRow: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        emit()
    }
}

// MARK: - ExtensionsJSONViewer

/// Read-only pretty-printed JSON viewer for `Character.extensions`. Power-
/// user surface (§3.7) — shows what's actually stored in the extensions
/// blob so authors can verify depth_prompt / rpclient/details / risuai
/// passthroughs round-trip correctly.
final class ExtensionsJSONViewer: NSView {

    private let labelView = NSTextField(labelWithString: "Extensions (JSON)")
    private let hintView = NSTextField(wrappingLabelWithString:
        "Read-only view of the card's extensions blob. Includes depth_prompt, rpclient/details, rpclient/intimacy, plus any passthrough keys from other clients (agnai, risuai, …). Edit-the-JSON-directly is intentionally not exposed.")
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "No extensions data on this card.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(extensions: [String: JSONValue]?) {
        if let ext = extensions, !ext.isEmpty {
            placeholderLabel.isHidden = true
            scroll.isHidden = false
            do {
                let data = try JSONEncoder.prettyPrinted.encode(ext)
                if let s = String(data: data, encoding: .utf8) {
                    textView.string = s
                }
            } catch {
                textView.string = "(failed to render extensions JSON)"
            }
        } else {
            placeholderLabel.isHidden = false
            scroll.isHidden = true
        }
    }

    private func buildUI() {
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        hintView.font = DesignTokens.Typography.subheadline
        hintView.textColor = DesignTokens.Foreground.secondary
        hintView.maximumNumberOfLines = 4
        hintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintView)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = DesignTokens.Typography.mono(.body)
        textView.textColor = DesignTokens.Foreground.primary
        textView.isEditable = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scroll.documentView = textView
        addSubview(scroll)

        placeholderLabel.font = DesignTokens.Typography.body
        placeholderLabel.textColor = DesignTokens.Foreground.tertiary
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: topAnchor),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),

            hintView.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: DesignTokens.Spacing.xs),
            hintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintView.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: hintView.bottomAnchor, constant: DesignTokens.Spacing.sm),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 280),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }
}

private extension JSONEncoder {
    static let prettyPrinted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

// MARK: - LorebookTabViewController (§5.3c.3)

/// Lorebook tab — read-only summary of `charBook` entries imported with the
/// card. Card-bound lorebook editing remains §6 out-of-scope; this surface
/// just shows the author what came along with the card so they know what
/// will fire during a chat. Per-chat lore stays editable in the inspector
/// pane (V2 Phase 1 §2.1 World Info).
final class LorebookTabViewController: NSViewController {
    private let draft: CharacterDraft

    init(draft: CharacterDraft) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let entries = draft.character.charBook
        var rows: [NSView] = [headerRow(count: entries.count)]
        if entries.isEmpty {
            rows.append(emptyStateRow())
        } else {
            rows.append(contentsOf: entries.map(LorebookEntryRow.init(entry:)))
        }
        rows.append(footerRow())
        self.view = makeScrollingTab(fields: rows)
    }

    private func headerRow(count: Int) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Character lorebook")
        header.font = DesignTokens.Typography.title2
        header.textColor = DesignTokens.Foreground.primary
        header.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: count == 0
            ? "No entries imported with this card."
            : "\(count) entr\(count == 1 ? "y" : "ies") imported with this card.")
        countLabel.font = DesignTokens.Typography.subheadline
        countLabel.textColor = DesignTokens.Foreground.secondary
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(countLabel)
        return stack
    }

    private func emptyStateRow() -> NSView {
        let label = NSTextField(wrappingLabelWithString:
            "This character didn't ship with a lorebook. Per-chat world-info " +
            "entries (which fire during a chat regardless of which card is " +
            "loaded) are edited in the World Info pane on the inspector.")
        label.font = DesignTokens.Typography.body
        label.textColor = DesignTokens.Foreground.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func footerRow() -> NSView {
        let label = NSTextField(wrappingLabelWithString:
            "Card-bound lorebook editing isn't yet supported in the creator. " +
            "Per-chat world-info edits live in the inspector's World Info pane.")
        label.font = DesignTokens.Typography.subheadline
        label.textColor = DesignTokens.Foreground.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

private final class LorebookEntryRow: NSView {

    init(entry: WorldInfoEntry) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(entry: entry)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(entry: WorldInfoEntry) {
        let card = AppearanceAwareLayerView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = DesignTokens.Background.group
        card.cornerRadiusValue = DesignTokens.Radius.section
        addSubview(card)

        let nameLabel = NSTextField(labelWithString: entry.name.isEmpty
            ? (entry.keys.first ?? "Untitled")
            : entry.name)
        nameLabel.font = DesignTokens.Typography.headline
        nameLabel.textColor = DesignTokens.Foreground.primary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let modePill = makeModePill(mode: entry.injectionMode, enabled: entry.enabled)
        let priorityLabel = NSTextField(labelWithString: "p\(entry.priority)")
        priorityLabel.font = DesignTokens.Typography.mono(.caption1)
        priorityLabel.textColor = DesignTokens.Foreground.tertiary
        priorityLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [nameLabel, NSView(), modePill, priorityLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = DesignTokens.Spacing.sm
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let keysLabel = NSTextField(labelWithString: keysSummary(entry))
        keysLabel.font = DesignTokens.Typography.subheadline
        keysLabel.textColor = DesignTokens.Foreground.secondary
        keysLabel.lineBreakMode = .byTruncatingTail
        keysLabel.maximumNumberOfLines = 1
        keysLabel.translatesAutoresizingMaskIntoConstraints = false

        let contentLabel = NSTextField(wrappingLabelWithString: entry.content)
        contentLabel.font = DesignTokens.Typography.body
        contentLabel.textColor = DesignTokens.Foreground.primary
        contentLabel.lineBreakMode = .byTruncatingTail
        contentLabel.maximumNumberOfLines = 3
        contentLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headerRow, keysLabel, contentLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: DesignTokens.Spacing.md),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DesignTokens.Spacing.md),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DesignTokens.Spacing.md),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -DesignTokens.Spacing.md),

            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // Disabled entries fade — they don't fire in the chat, the author
        // should see at-a-glance which are dormant.
        if !entry.enabled {
            self.alphaValue = 0.5
        }
    }

    private func keysSummary(_ entry: WorldInfoEntry) -> String {
        var bits: [String] = []
        if !entry.keys.isEmpty {
            bits.append("keys: " + entry.keys.joined(separator: ", "))
        }
        if !entry.secondaryKeys.isEmpty {
            bits.append("AND " + entry.secondaryKeys.joined(separator: ", "))
        }
        return bits.isEmpty ? "no keys" : bits.joined(separator: " ")
    }

    private func makeModePill(mode: WorldInfoInjectionMode, enabled: Bool) -> NSView {
        let title: String
        switch mode {
        case .always: title = "always"
        case .keyword: title = "keyword"
        case .vectorized: title = "vector"
        }
        let label = NSTextField(labelWithString: title)
        label.font = DesignTokens.Typography.caption2
        label.textColor = enabled ? DesignTokens.Foreground.secondary : DesignTokens.Foreground.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.drawsBackground = false

        let wrap = AppearanceAwareLayerView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.backgroundColor = DesignTokens.Background.window
        wrap.cornerRadiusValue = DesignTokens.Radius.chip
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
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
