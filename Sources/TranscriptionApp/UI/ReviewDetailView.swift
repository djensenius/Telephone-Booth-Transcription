import SwiftUI
import TranscriptionPipeline
import TranscriptionReview

/// Everything about one message, and every action that can be taken on it.
///
/// The queue list stays glanceable by delegating all controls here, so the
/// transcript and translation get the full width they need instead of being
/// clipped to a couple of lines between two buttons (issue #79).
struct ReviewDetailView: View {
    let message: Message
    let store: ReviewStore
    let onDevice: OnDeviceReviewPipeline?

    /// Held outside this view because it is `.id(message.id)`-scoped: its
    /// `@State` dies on every selection change and navigation pop, which would
    /// throw away a hand-typed translation, or one a failed submit kept for the
    /// operator to retry.
    let drafts: ReviewDraftStore

    private var translationDraft: String {
        get { drafts[message.id].translation }
        nonmutating set { drafts[message.id].translation = newValue }
    }

    private var notesDraft: String {
        get { drafts[message.id].notes }
        nonmutating set { drafts[message.id].notes = newValue }
    }

    /// The text the local verdict on screen was computed from, so an edit that
    /// makes it stale can be detected.
    private var moderatedText: String? {
        get { drafts[message.id].moderatedText }
        nonmutating set { drafts[message.id].moderatedText = newValue }
    }

    private var isActing: Bool { store.isActing(on: message.id) }
    /// The Operator accepts corrections and replacement decisions only for
    /// explicitly supported states after an upload has completed.
    private var canModify: Bool { message.status.allowsReviewChanges }
    private var output: OnDeviceReviewPipeline.Output? { onDevice?.outputs[message.id] }
    private var advice: AIRecommendation? {
        AIRecommendation(message: message)
    }

    /// True when this device can run the whole review locally in one pass —
    /// transcribe, translate, and moderate. When it can, an operator shouldn't
    /// have to submit a transcript before the translation and recommendation can
    /// run (issue #84); one button drafts all three.
    private var supportsLocalFullPipeline: Bool {
        onDevice?.supportsTranscription == true
            && onDevice?.supportsTranslation == true
            // Moderation too: the copy on this button promises a recommendation,
            // and a one-press run that quietly can't produce one would send the
            // operator looking for a verdict that was never coming.
            && onDevice?.supportsModeration == true
    }

    /// A complete on-device draft — transcript, translation, and recommendation —
    /// produced for a message the Operator holds no *usable* transcript for:
    /// none at all, or a newest row that is still pending or has failed. This
    /// is what the one-press "Draft with Apple Intelligence" run leaves behind:
    /// everything is ready to review, and a single Submit posts the transcript
    /// and the translation together.
    private var localReviewDraft: OnDeviceReviewPipeline.Output? {
        guard message.needsTranscriptionWork,
              let output,
              !output.transcript.isEmpty,
              output.translation != nil else { return nil }
        return output
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                header
                #if !os(macOS)
                // Actions all live on this screen, and this is a pushed view —
                // an error reported back in the list would be hidden behind it.
                // On macOS the list header is visible alongside this, and
                // reports it there instead.
                if let actionError = store.actionError {
                    Label(actionError, systemImage: "xmark.octagon.fill")
                        .font(Theme.Fonts.bodyMedium)
                        .foregroundStyle(Theme.Colors.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.medium)
                        .background(Theme.Colors.error.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                }
                #endif
                if let advice {
                    recommendationCard(advice)
                } else {
                    noRecommendationCard
                }
                transcriptCard
                translationCard
                if canModify { decisionCard }
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            // The pipeline outlives this view, so a translation generated
            // before a navigation pop would otherwise be stranded: the output
            // survives, but the draft it was copied into does not.
            if translationDraft.isEmpty, let translation = output?.translation {
                translationDraft = translation
            }
        }
        .onChange(of: transcriptionSnapshot) {
            // A new transcript replaced the one being translated; drop the draft
            // so it can't be submitted against the wrong source text. The
            // pipeline output is reset by the queue, which sees every row.
            //
            // Keyed to the text as well as the id, because the Operator can
            // finalize a pending transcription in place: same id, entirely
            // different source text.
            //
            // Not while this device is writing that text: the write moved the
            // snapshot itself and owns these drafts until it finishes. The
            // queue applies the same rule for the rows it can't see.
            guard !store.isWritingText(for: message.id) else { return }
            drafts.clear(message.id)
        }
        .onChange(of: translationDraft) {
            // The verdict was computed from the draft as it stood. Editing it
            // makes that verdict describe text that no longer exists, so drop
            // it rather than let it sit above the decision buttons.
            guard let moderatedText, moderatedText != englishForModeration else { return }
            onDevice?.clearModeration(message.id)
            self.moderatedText = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                StatusPill(text: message.status.displayName, tint: statusTint)
                if let step = message.nextStep { StepChip(step: step) }
                Spacer(minLength: 0)
            }
            Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            if let notes = message.notes, !notes.isEmpty {
                Text(notes)
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusTint: Color {
        switch message.status {
        case .approved: return Theme.Colors.success
        case .rejected: return Theme.Colors.error
        case .pending, .received: return Theme.Colors.warning
        default: return Theme.Colors.info
        }
    }

    // MARK: - AI recommendation

    private func recommendationCard(_ advice: AIRecommendation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: advice.systemImage)
                    .foregroundStyle(advice.tint)
                Text(advice.recommendation.displayName)
                    .font(Theme.Fonts.headerLarge())
                    .foregroundStyle(advice.tint)
                if advice.flagged {
                    StatusPill(text: "Flagged", tint: Theme.Colors.error)
                    if let score = advice.flaggedScoreLabel {
                        Text(score)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.error)
                    }
                }
                Spacer(minLength: 0)
                Text(advice.source)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let reason = advice.reason, !reason.isEmpty {
                Text(reason)
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only true while the decision is still open; the All filter shows
            // decided messages, whose recommendation is now just history.
            Text(message.isReviewable
                 ? "A recommendation, not a decision — you still approve or reject."
                 : "A recommendation — the decision was made by a person.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            if canModify,
               let onDevice,
               onDevice.supportsModeration,
               let text = operatorEnglish {
                Divider().overlay(Theme.Colors.textSecondary.opacity(0.2))
                if let localAdvice, moderatedText != nil {
                    localVerdictReview(localAdvice, using: onDevice)
                } else {
                    regenerationMenu(
                        title: "Regenerate recommendation",
                        systemImage: "apple.intelligence",
                        preview: {
                            await generateRecommendation(
                                using: onDevice, text: text, saveToOperator: false
                            )
                        },
                        save: {
                            await generateRecommendation(
                                using: onDevice, text: text, saveToOperator: true
                            )
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .background(advice.tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(advice.tint.opacity(0.35), lineWidth: 1)
        )
    }

    /// Shown when there is no verdict to render. The Operator's verdict is the
    /// one of record, but it can be missing for three genuinely different
    /// reasons — moderation was never asked for, it's still **pending**, or it
    /// **failed** — and a blank space collapsed all three into one. This card
    /// names the state (and shows a failure's error), then offers the local
    /// Apple Intelligence fallback when one is available. Without that fallback
    /// the Decide state — where the recommendation matters most — had no way to
    /// get one.
    @ViewBuilder
    private var noRecommendationCard: some View {
        let state = moderationDisplayState
        let canRunLocal = canModify
            && (onDevice?.supportsModeration ?? false)
            && englishForModeration != nil
        // Nothing to say and nothing to do — don't render an empty card. Only
        // the "never asked, and can't ask locally" case falls through here.
        if canRunLocal || state.hasStatus {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                moderationStateHeader(state)
                if canRunLocal, let onDevice, let text = englishForModeration {
                    // A verdict computed on this device stays local until
                    // submitted: the pipeline never uploads on its own. Show it
                    // with a Submit action, exactly as a locally produced
                    // transcript is shown.
                    if let localAdvice, moderatedText != nil {
                        localVerdictReview(localAdvice, using: onDevice)
                    } else {
                        onDeviceModerationAction(onDevice: onDevice, text: text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.medium)
            .background(Theme.Colors.tertiaryBackground.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }

    /// The verdict this device just computed, ready to review and submit. Nil
    /// until a local moderation run has produced one.
    private var localAdvice: AIRecommendation? {
        output.flatMap(AIRecommendation.init(localOutput:))
    }

    /// Shows the on-device verdict and a deliberate Submit action. On success
    /// the local verdict is cleared: it is now persisted on the Operator, so
    /// `message.latestModeration` becomes the source of truth for every device.
    @ViewBuilder
    private func localVerdictReview(
        _ advice: AIRecommendation,
        using onDevice: OnDeviceReviewPipeline
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: advice.systemImage)
                    .foregroundStyle(advice.tint)
                Text(advice.recommendation.displayName)
                    .font(Theme.Fonts.headerLarge())
                    .foregroundStyle(advice.tint)
                if advice.flagged {
                    StatusPill(text: "Flagged", tint: Theme.Colors.error)
                    if let score = advice.flaggedScoreLabel {
                        Text(score)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.error)
                    }
                }
                Spacer(minLength: 0)
                Text(advice.source)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            caption("Computed on this device. Save it to the Operator server to replace "
                    + "the shared recommendation.")
            if localVerdictIsSubmittable {
                HStack {
                    Spacer()
                    Button {
                        Task { await submitLocalVerdict(using: onDevice) }
                    } label: {
                        actionLabel("Save recommendation to server",
                                    systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.tbtGlass)
                    .disabled(onDevice.isRunning(message.id) || isActing)
                }
            } else {
                // The verdict is stored against the Operator's transcription, so
                // publishing one computed from a draft nobody has submitted would
                // attach a recommendation to text the Operator doesn't hold.
                caption("""
                    This judged a draft the Operator doesn't have yet. Submit the \
                    translation and the recommendation can go with it.
                    """)
            }
        }
    }

    /// The English the Operator actually holds for this message — its
    /// translation of record, or the transcript when nothing is translated yet.
    private var operatorEnglish: String? {
        message.translationText ?? message.latestTranscription?.text
    }

    /// Whether the verdict on screen describes the text the Operator holds. A
    /// submitted verdict is attached to `latestTranscription`, so a verdict
    /// computed from an unsubmitted local draft would read, on every other
    /// device, as a recommendation about entirely different text.
    private var localVerdictIsSubmittable: Bool {
        guard let moderatedText, let operatorEnglish else { return false }
        // Trim-insensitive: the transport trims, so the Operator's copy of a
        // draft that had stray whitespace is the trimmed form of it.
        return moderatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            == operatorEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retires the local work behind a translation that has just landed on the
    /// Operator.
    ///
    /// The verdict is the exception: it was computed for exactly `submitted`,
    /// which is now the Operator's translation of record, so it has become
    /// submittable rather than stale. Throwing it away here would make the
    /// card's "submit the translation and the recommendation can go with it"
    /// promise unkeepable — the operator would have to recompute a verdict they
    /// are already looking at. Anything else the pipeline produced is spent.
    private func retireLocalWork(after submitted: String) {
        // The transport trims before sending, so the Operator's copy of record
        // is the trimmed text. Compare — and retain — the same form, or a draft
        // with stray whitespace would never match what came back.
        let sent = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard moderatedText?.trimmingCharacters(in: .whitespacesAndNewlines) == sent,
              output?.recommendation != nil else {
            onDevice?.reset(message.id)
            drafts.clear(message.id)
            moderatedText = nil
            return
        }
        // Only the draft goes. `englishForModeration` then falls through to the
        // Operator's translation, which is this same text, so the verdict stays
        // matched rather than being dropped as stale.
        translationDraft = ""
        moderatedText = sent
    }

    /// Posts the on-device verdict to the Operator and, on success, clears the
    /// local result so it can't be submitted twice.
    private func submitLocalVerdict(using onDevice: OnDeviceReviewPipeline) async {
        guard canModify,
              localVerdictIsSubmittable,
              let moderationInput = moderatedText,
              let output, let recommendation = output.recommendation else { return }
        let submitted = await store.submitModeration(
            message,
            inputText: moderationInput,
            flagged: output.flagged ?? false,
            recommendation: recommendation,
            maxScore: output.maxScore ?? 0,
            model: output.moderationModel
        )
        if submitted {
            onDevice.clearModeration(message.id)
            moderatedText = nil
        }
    }

    /// The Operator's moderation state, reduced to the three cases the UI draws
    /// differently. `succeeded` moderation carries its own recommendation and is
    /// rendered by `recommendationCard`, so it collapses to `.none` here.
    private var moderationDisplayState: ModerationDisplayState {
        guard let moderation = message.latestModeration else { return .none }
        if moderation.isPending { return .pending(moderation) }
        if moderation.didFail { return .failed(moderation) }
        return .none
    }

    /// Names why there's no recommendation, in the same visual language the
    /// transcript and translation cards use: a failure is red and carries its
    /// error, a pending run reads as still-working, and a never-asked message
    /// stays neutral. All three name the engine so an operator knows what would
    /// have produced (or is producing) the verdict.
    @ViewBuilder
    private func moderationStateHeader(_ state: ModerationDisplayState) -> some View {
        switch state {
        case .pending(let moderation):
            Text("Moderation in progress")
                .font(Theme.Fonts.bodyLarge)
                .foregroundStyle(Theme.Colors.textPrimary)
            caption("The Operator is still checking this message with \(moderation.sourceLabel).")
        case .failed(let moderation):
            Text("Moderation failed")
                .font(Theme.Fonts.bodyLarge)
                .foregroundStyle(Theme.Colors.textPrimary)
            // A failed run must not look like one that never happened: the fix
            // is different (retry vs. start), and the error explains why.
            Label("The automatic moderation failed.", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.Colors.error)
            if let error = moderation.error, !error.isEmpty {
                caption(error)
            }
            caption("Engine: \(moderation.sourceLabel)")
        case .none:
            Text("No recommendation yet")
                .font(Theme.Fonts.bodyLarge)
                .foregroundStyle(Theme.Colors.textPrimary)
            caption("The Operator has no recommendation for this message.")
        }
    }

    /// The local Apple Intelligence fallback: a button that classifies the
    /// English on screen without the text leaving the device.
    @ViewBuilder
    private func onDeviceModerationAction(
        onDevice: OnDeviceReviewPipeline,
        text: String
    ) -> some View {
        // `running` drives this card's own spinner; `busy` disables it while
        // any operation holds the pipeline, since a second one can't start.
        let busy = onDevice.isRunning(message.id)
        let running = busy && owns(.moderate)
        let savesAutomatically = matchesCurrentOperatorEnglish(text)
        caption(savesAutomatically
                ? "Apple Intelligence can weigh in from here. Because this message has "
                    + "no recommendation yet, the result is saved to the Operator server "
                    + "automatically."
                : "This translation is still a local draft. Preview a recommendation, "
                    + "then save the translation before saving its recommendation.")
        HStack {
            Button {
                Task {
                    await generateRecommendation(
                        using: onDevice, text: text, saveToOperator: savesAutomatically
                    )
                }
            } label: {
                if running {
                    HStack(spacing: Theme.Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text(stageLabel(onDevice.stage(for: message.id)))
                    }
                } else {
                    Label(savesAutomatically
                          ? "Generate and save recommendation"
                          : "Preview recommendation",
                          systemImage: "apple.intelligence")
                }
            }
            .buttonStyle(.tbtGlass)
            .disabled(busy || isActing)
            Spacer()
        }
        if case .failed(let reason) = onDevice.stage(for: message.id), owns(.moderate) {
            Text(reason)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.error)
        }
    }

    private func generateRecommendation(
        using onDevice: OnDeviceReviewPipeline,
        text: String,
        saveToOperator: Bool
    ) async {
        guard canModify else { return }
        let moderationInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recommendation = await onDevice.moderateOnly(
            moderationInput,
            transcript: message.latestTranscription?.text ?? text,
            language: message.latestTranscription?.language,
            for: message.id
        )
        guard let recommendation,
              onDevice.outputs[message.id]?.recommendation == recommendation else { return }

        guard englishForModeration == text else {
            onDevice.clearModeration(message.id)
            return
        }
        moderatedText = moderationInput
        if saveToOperator,
           matchesCurrentOperatorEnglish(moderationInput),
           await saveGeneratedRecommendation(using: onDevice, inputText: moderationInput) {
            onDevice.clearModeration(message.id)
            moderatedText = nil
        }
    }

    private func saveGeneratedRecommendation(
        using onDevice: OnDeviceReviewPipeline,
        inputText: String
    ) async -> Bool {
        guard canModify,
              let output = onDevice.outputs[message.id],
              let recommendation = output.recommendation else { return false }
        return await store.submitModeration(
            message,
            inputText: inputText,
            flagged: output.flagged ?? false,
            recommendation: recommendation,
            maxScore: output.maxScore ?? 0,
            model: output.moderationModel
        )
    }

    private func matchesCurrentOperatorEnglish(_ text: String) -> Bool {
        guard let current = store.message(id: message.id) else { return false }
        let currentEnglish = current.translationText ?? current.latestTranscription?.text
        guard let currentEnglish else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            == currentEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a local moderation run should classify: the English the operator
    /// moderates on. An edited draft wins, because it's what they're about to
    /// submit and a recommendation describing anything else is misleading. Then
    /// the Operator's translation, the one of record; then a locally generated
    /// one; and only then the source transcript — which may not be English at
    /// all, but is better than refusing to classify a message nobody has
    /// translated yet.
    private var englishForModeration: String? {
        let draft = translationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (draft.isEmpty ? nil : translationDraft)
            ?? message.translationText
            ?? output?.translation
            ?? message.latestTranscription?.text
        guard let candidate,
              !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return candidate
    }

    /// What the Operator holds for this message, as a value that changes
    /// whenever the authoritative source text does — including a pending
    /// transcription finalized in place under the same id.
    private var transcriptionSnapshot: String? {
        guard let transcription = message.latestTranscription else { return nil }
        return transcription.id + "\u{1F}" + (transcription.text ?? "")
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptCard: some View {
        card(title: "Transcript", systemImage: "waveform") {
            if let text = message.latestTranscription?.text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bodyText(text)
                if let language = message.latestTranscription?.language {
                    caption("Detected language: \(language)")
                }
            } else if message.transcriptionIsSilent {
                caption("Silent recording — the transcription returned no speech.")
            } else if message.transcriptionIsUnfinished, !message.transcriptionFailed {
                caption("Transcribing…")
            } else if message.transcriptionFailed {
                // Branch on the failure, not on the error string: it's optional,
                // and without this a failure that carries no detail would read
                // as a message nobody has tried yet.
                Text(message.latestTranscription?.error ?? "Transcription failed.")
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.Colors.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                caption("No transcription yet.")
            }

            if let onDevice, let output, output.transcript != message.latestTranscription?.text {
                Divider().overlay(Theme.Colors.textSecondary.opacity(0.2))
                caption("Transcribed on this device")
                if output.transcript.isEmpty {
                    Text("No speech detected.")
                        .font(Theme.Fonts.bodyMedium)
                        .italic()
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    bodyText(output.transcript)
                }
                if localReviewDraft != nil, canModify {
                    // The transcript and the translation it produced are
                    // submitted together from the translation card below, so
                    // there is no separate transcript submit here.
                    caption("Translated and checked below — review the translation, "
                            + "then submit both in one step.")
                } else if canModify {
                    caption(message.latestTranscription == nil
                            ? (isActing
                               ? "Saving this first transcript to the Operator server…"
                               : "This transcript is ready. Save it to the Operator server "
                                   + "to make it available to every reviewer.")
                            : "This is a local preview. Save it to the Operator server "
                                + "to make it the newest transcript.")
                    HStack {
                        Spacer()
                        Button {
                            Task { await submitOnDeviceTranscript(output, using: onDevice) }
                        } label: {
                            actionLabel("Save transcript to server",
                                        systemImage: "arrow.up.circle.fill")
                        }
                        .buttonStyle(.tbtGlass)
                        .disabled(onDevice.isRunning(message.id) || isActing)
                    }
                }
            }

            // The controls that produce this text belong with it. Kept as a
            // footer rather than a card of its own so the detail reads as one
            // step per card: transcript, translation, decision.
            if canModify, canRunTranscription { transcriptionRunFooter }
        }
    }

    /// False when the device has no on-device transcriber. There is no button
    /// to show, so the footer and its explanatory caption would be dangling.
    private var canRunTranscription: Bool {
        // A moderation-only pipeline exists but has no transcriber, so its
        // presence alone doesn't mean there's a button under this footer.
        return onDevice?.supportsTranscription == true
    }

    @ViewBuilder
    private var transcriptionRunFooter: some View {
        Divider().overlay(Theme.Colors.textSecondary.opacity(0.2))

        if supportsLocalFullPipeline && message.needsTranscriptionWork {
            // One press runs the whole review locally — transcribe, translate,
            // and moderate — so the operator never has to submit a transcript
            // just to unlock translation and a recommendation (issue #84).
            if output == nil {
                caption("Apple Intelligence can transcribe, translate, and check this "
                        + "message in one pass — the audio never leaves this device. "
                        + "The result is saved to the Operator server automatically.")
            }
            onDeviceTranslateActions
        } else {
            onDeviceTranscribeActions
        }

        if message.latestTranscription != nil {
            caption("Saving a re-run keeps the old transcript in history and makes "
                    + "the new version current.")
        }
    }

    // MARK: - Translation

    @ViewBuilder
    private var translationCard: some View {
        card(title: "English translation", systemImage: "character.book.closed") {
            if let translation = message.translationText {
                // An English-language message round-trips unchanged, and
                // printing the same paragraph twice under two headings reads
                // like a bug. Say so instead.
                if translation == message.latestTranscription?.text {
                    caption("Already in English — the transcript needed no translation.")
                } else {
                    bodyText(translation)
                    if let provider = message.latestTranscription?.translationProvider {
                        caption("Translated by \(provider.displayName)")
                    }
                }
            } else if message.translationFailed {
                // Called out explicitly: a failed run must not look like one that
                // never happened, because the fix is different (retry vs. start).
                Label("The automatic translation failed.", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.Colors.error)
                if let error = message.latestTranscription?.translationError, !error.isEmpty {
                    caption(error)
                }
            } else if message.translationIsPending {
                caption("Translating…")
            } else if localReviewDraft != nil {
                // A full on-device draft is ready below; the "waiting on a
                // transcript" copy would be wrong here.
                EmptyView()
            } else if !message.needsTranslation {
                // No transcript to translate yet: say so rather than render an
                // empty card.
                caption(message.transcriptionIsSilent
                        ? "Nothing to translate — the recording was silent."
                        : "Waiting on a transcript.")
            }

            if message.needsTranslation, canModify {
                onDeviceTranslateActions
                translationEditor
            } else if localReviewDraft != nil, canModify {
                localReviewDraftEditor
            } else if message.translationText != nil, canModify {
                translationRegenerationActions
                if !translationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    translationEditor
                }
            }
        }
    }

    /// The editor for a translation the operator has yet to submit, whether it
    /// came from the Operator's queue or was drafted on this device.
    private var translationTextField: some View {
        TextField(
            "English translation",
            text: Binding(get: { translationDraft }, set: { translationDraft = $0 }),
            axis: .vertical
        )
            .textFieldStyle(.plain)
            .lineLimit(3...12)
            .font(Theme.Fonts.bodyLarge)
            .padding(Theme.Spacing.small)
            .background(Theme.Colors.secondaryBackground.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .disabled(isActing)
    }

    @ViewBuilder
    private var translationEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(message.translationFailed ? "Write the translation yourself" : "Your translation")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            translationTextField

            HStack {
                Spacer()
                Button {
                    let text = translationDraft
                    Task {
                        let submitted = await store.submitTranslation(message, text: text)
                        // Only on success: the message moves to Decide, where a
                        // local verdict computed for the pipeline's own
                        // translation rather than the text the operator
                        // submitted would be the only recommendation on screen.
                        // A failure has to keep the draft and its output, or a
                        // transient error would discard the work being retried.
                        if submitted { retireLocalWork(after: text) }
                    }
                } label: {
                    actionLabel(message.translationText == nil
                                ? "Save translation to server"
                                : "Replace server translation",
                                systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.tbtGlass)
                .disabled(isActing || translationDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The editor for a fully local draft, whose single Submit posts the
    /// transcript and the translation together — so an operator who ran the
    /// whole review on-device never has to submit a transcript first (issue
    /// #84).
    @ViewBuilder
    private var localReviewDraftEditor: some View {
        if let draft = localReviewDraft {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Your translation")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)

                translationTextField

                caption("Drafted on this device from the transcript above — no audio or "
                        + "text was sent to an AI service. Submitting posts the transcript "
                        + "and this translation together.")

                HStack {
                    Spacer()
                    Button {
                        let text = translationDraft
                        Task {
                            let submitted = await store.submitTranscriptAndTranslation(
                                message,
                                transcript: draft.transcript,
                                language: draft.language,
                                model: draft.model,
                                translation: text
                            )
                            // On success only the spent local work goes: a
                            // verdict computed for exactly this text is now a
                            // verdict about the Operator's translation of
                            // record, so it survives and can be submitted. On
                            // failure everything stays — the transcript may have
                            // landed while the translation didn't, and the
                            // translation card's plain retry needs the draft.
                            if submitted { retireLocalWork(after: text) }
                        }
                    } label: {
                        actionLabel("Save transcript and translation to server",
                                    systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.tbtGlass)
                    .disabled(isActing || onDevice?.isRunning(message.id) == true
                              || translationDraft.trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// First-time Apple Intelligence entry point. A missing result is saved
    /// immediately; regeneration uses the explicit preview/save menu below.
    @ViewBuilder
    private var onDeviceTranslateActions: some View {
        if let onDevice,
           onDevice.supportsTranslation,
           (!message.needsTranscriptionWork || onDevice.supportsTranscription) {
            let stage = onDevice.stage(for: message.id)
            let busy = onDevice.isRunning(message.id)
            let running = busy && owns(.translate)

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if output == nil {
                    caption("This message has no saved translation yet. Apple Intelligence "
                            + "will generate one and save it to the Operator server "
                            + "automatically.")
                }
                HStack {
                    Button {
                        Task {
                            await generateTranslation(
                                using: onDevice, saveToOperator: true
                            )
                        }
                    } label: {
                        if running {
                            HStack(spacing: Theme.Spacing.small) {
                                ProgressView().controlSize(.small)
                                Text(stageLabel(stage))
                            }
                        } else {
                            Label(message.translationFailed
                                  ? "Retry and save translation"
                                  : "Generate and save translation",
                                  systemImage: "apple.intelligence")
                        }
                    }
                    .buttonStyle(.tbtGlass)
                    .disabled(busy || isActing)
                    Spacer()
                }

                if case .failed(let reason) = stage, owns(.translate) {
                    Text(reason)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.error)
                }

                if output != nil {
                    caption("Processed on this device. If saving failed, the result remains "
                            + "here so it can be retried.")
                }
            }
        }
    }

    @ViewBuilder
    private var translationRegenerationActions: some View {
        if let onDevice, onDevice.supportsTranslation {
            regenerationMenu(
                title: "Regenerate translation",
                systemImage: "apple.intelligence",
                preview: {
                    await generateTranslation(using: onDevice, saveToOperator: false)
                },
                save: {
                    await generateTranslation(using: onDevice, saveToOperator: true)
                }
            )
        }
    }

    private func generateTranslation(
        using onDevice: OnDeviceReviewPipeline,
        saveToOperator: Bool
    ) async {
        guard canModify else { return }
        let draftBefore = translationDraft
        let translation: String?
        if message.needsTranscriptionWork {
            translation = await onDevice.run(for: message)
        } else if let transcript = message.latestTranscription?.text {
            translation = await onDevice.translateOnly(
                transcript,
                sourceLanguage: message.latestTranscription?.language,
                transcriptModel: message.latestTranscription?.model,
                for: message.id
            )
        } else {
            return
        }
        // `reset` can land between `run` returning and this continuation
        // resuming, so re-check against the pipeline's current output rather
        // than trusting the returned value — otherwise a cleared draft gets
        // repopulated with a superseded translation.
        guard let translation,
              onDevice.outputs[message.id]?.translation == translation
        else { return }

        // The editor stays enabled while this runs, so anything typed meanwhile
        // is the operator's own work and outranks the generated text. The
        // verdict describes the translation they didn't take, so it goes rather
        // than sitting above their draft.
        guard translationDraft == draftBefore else {
            onDevice.clearModeration(message.id)
            return
        }

        translationDraft = translation
        // `run` moderates the translation it just produced, so the draft starts
        // out as the moderated text — without this, editing it would leave that
        // verdict on screen.
        if onDevice.outputs[message.id]?.recommendation != nil {
            moderatedText = translation
        }

        guard saveToOperator, let output = onDevice.outputs[message.id] else { return }
        let result = await store.submitGeneratedReview(
            message,
            expectedTranscriptionID: message.latestTranscription?.id,
            expectedTranscriptionStatus: message.latestTranscription?.status,
            expectedSourceTranscript: message.latestTranscription?.text,
            transcript: message.needsTranscriptionWork ? output.transcript : nil,
            language: output.language,
            transcriptionModel: output.model,
            translation: translation,
            flagged: output.flagged,
            recommendation: output.recommendation,
            maxScore: output.maxScore ?? 0,
            moderationModel: output.moderationModel
        )
        switch result {
        case .saved, .superseded:
            onDevice.reset(message.id)
            drafts.clear(message.id)
        case .failed:
            break
        }
    }

    // MARK: - Decision

    private var decisionCard: some View {
        card(title: "Decision", systemImage: "checkmark.seal") {
            if !message.isReviewable {
                caption("Current decision: \(message.status.displayName). You can replace it below.")
            } else if message.nextStep != .decision {
                caption("You can decide now, or finish the step above first for more context.")
            }

            TextField(
                "Notes (optional)",
                text: Binding(get: { notesDraft }, set: { notesDraft = $0 }),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(Theme.Fonts.bodyMedium)
                .padding(Theme.Spacing.small)
                .background(Theme.Colors.secondaryBackground.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .disabled(isActing)

            HStack(spacing: Theme.Spacing.small) {
                Button {
                    let notes = notesDraft
                    Task { await store.decide(message, .reject, notes: notes) }
                } label: {
                    actionLabel("Reject", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.tbtGlass)
                .tint(Theme.Colors.error)
                .disabled(isActing)

                Button {
                    let notes = notesDraft
                    Task { await store.decide(message, .approve, notes: notes) }
                } label: {
                    actionLabel("Approve", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.tbtGlass)
                .tint(Theme.Colors.success)
                .disabled(isActing)
            }
        }
    }

    // MARK: - Transcription runs

    /// Transcribes locally with Apple Intelligence. A first transcript is saved
    /// automatically; a re-run stays local until the operator chooses to
    /// replace the Operator version.
    @ViewBuilder
    private var onDeviceTranscribeActions: some View {
        if let onDevice, onDevice.supportsTranscription {
            let stage = onDevice.stage(for: message.id)
            let busy = onDevice.isRunning(message.id)
            let running = busy && owns(.transcribe)

            HStack {
                Button {
                    Task {
                        let transcript = await onDevice.transcribeOnly(for: message)
                        if transcript != nil,
                           message.latestTranscription == nil,
                           store.message(id: message.id)?.latestTranscription == nil,
                           let output = onDevice.outputs[message.id] {
                            await submitOnDeviceTranscript(output, using: onDevice)
                        }
                    }
                } label: {
                    if running {
                        HStack(spacing: Theme.Spacing.small) {
                            ProgressView().controlSize(.small)
                            Text(stageLabel(stage))
                        }
                    } else {
                        Label(message.latestTranscription == nil
                              ? "Transcribe and save to server"
                              : "Re-run transcription preview",
                              systemImage: "apple.intelligence")
                    }
                }
                .buttonStyle(.tbtGlass)
                .disabled(busy || isActing)
                Spacer()
            }

            if case .failed(let reason) = stage, owns(.transcribe) {
                Text(reason)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.error)
            }
        }
    }

    /// Posts a locally produced transcript to the Operator and, on success,
    /// clears the on-device result so it can't be submitted twice.
    private func submitOnDeviceTranscript(
        _ output: OnDeviceReviewPipeline.Output,
        using onDevice: OnDeviceReviewPipeline
    ) async {
        guard canModify else { return }
        let submitted = await store.submitTranscription(
            message,
            text: output.transcript,
            language: output.language,
            model: output.model
        )
        if submitted {
            onDevice.reset(message.id)
            // The queue's snapshot rule leaves local work alone while this
            // action is in flight, so clear the drafts here instead.
            drafts.clear(message.id)
        }
    }

    // MARK: - Building blocks

    private func regenerationMenu(
        title: String,
        systemImage: String,
        preview: @escaping @MainActor () async -> Void,
        save: @escaping @MainActor () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            caption("Choose whether to keep the regenerated result as a local preview "
                    + "or replace the version on the Operator server.")
            HStack {
                Menu {
                    Button {
                        Task { await preview() }
                    } label: {
                        Label("Regenerate preview only", systemImage: "eye")
                    }
                    Button {
                        Task { await save() }
                    } label: {
                        Label("Regenerate and replace server version",
                              systemImage: "arrow.up.circle.fill")
                    }
                } label: {
                    Label(title, systemImage: systemImage)
                }
                .buttonStyle(.tbtGlass)
                .disabled(onDevice?.isRunning(message.id) == true || isActing)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label(title, systemImage: systemImage)
                .font(Theme.Fonts.headerLarge())
                .foregroundStyle(Theme.Colors.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// Full-width, selectable, never truncated — the fix for the clipped
    /// translation text called out in #79.
    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.bodyLarge)
            .foregroundStyle(Theme.Colors.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        if isActing {
            ProgressView().controlSize(.small)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    /// True when the pipeline's current stage for this message belongs to
    /// `operation`. Three cards can offer an on-device action on the same
    /// message, but the pipeline runs one at a time — without this each of them
    /// would show the others' spinner and error as its own.
    private func owns(_ operation: OnDeviceReviewPipeline.Operation) -> Bool {
        onDevice?.operation(for: message.id) == operation
    }

    private func stageLabel(_ stage: OnDeviceReviewPipeline.Stage) -> String {
        switch stage {
        case .fetchingAndTranscribing: return "Transcribing…"
        case .translating: return "Translating…"
        case .moderating: return "Checking…"
        default: return "Working…"
        }
    }
}

/// The Operator's moderation reduced to the states the detail view renders
/// differently. A succeeded verdict is handled by `recommendationCard`, so only
/// pending, failed, and "nothing to show" reach here.
private enum ModerationDisplayState {
    case none
    case pending(Moderation)
    case failed(Moderation)

    /// True when there is a state worth drawing even without a local fallback:
    /// a pending run or a failure the operator needs to see.
    var hasStatus: Bool {
        switch self {
        case .none: return false
        case .pending, .failed: return true
        }
    }
}
