import SwiftUI
import TranscriptionOperator
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
    private var isQueued: Bool { store.isTranscriptionQueued(message.id) }
    private var output: OnDeviceReviewPipeline.Output? { onDevice?.outputs[message.id] }
    private var advice: AIRecommendation? {
        AIRecommendation(message: message)
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
                if message.awaitingModerationDecision { decisionCard }
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
                }
                Spacer(minLength: 0)
                Text(advice.source)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
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

    /// Shown when nobody has an opinion yet. The Operator's verdict is the one
    /// of record, but it can be missing — moderation was never asked for, or it
    /// failed — and until now the local fallback was only reachable through the
    /// translate button, which is hidden once a message is translated. That left
    /// exactly the Decide state, where the recommendation matters most, with no
    /// way to get one.
    @ViewBuilder
    private var noRecommendationCard: some View {
        if message.isReviewable, let onDevice, onDevice.supportsModeration,
           let text = englishForModeration {
            // `running` drives this card's own spinner; `busy` disables it while
            // any operation holds the pipeline, since a second one can't start.
            let busy = onDevice.isRunning(message.id)
            let running = busy && owns(.moderate)
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("No recommendation yet")
                    .font(Theme.Fonts.bodyLarge)
                    .foregroundStyle(Theme.Colors.textPrimary)
                // Deliberately neutral about *why*: the Operator may never have
                // been asked, or its moderation may have failed or still be
                // running. All three land here.
                caption("The Operator has no recommendation for this message. Apple "
                        + "Intelligence can weigh in from here — the text never leaves "
                        + "this device.")

                // A verdict computed on this device stays local until submitted:
                // the pipeline never uploads on its own. Show it with a Submit
                // action, exactly as a locally produced transcript is shown.
                if let localAdvice, moderatedText != nil {
                    localVerdictReview(localAdvice, using: onDevice)
                } else {
                    HStack {
                        Button {
                            Task {
                                let recommendation = await onDevice.moderateOnly(
                                    text,
                                    transcript: message.latestTranscription?.text ?? text,
                                    language: message.latestTranscription?.language,
                                    for: message.id
                                )
                                // The draft is editable while this is suspended, so
                                // a verdict that arrives against text the operator
                                // has since changed is already stale. Compared
                                // against the candidate rather than the draft,
                                // which is empty in the Decide state this button
                                // exists for.
                                if recommendation != nil {
                                    if englishForModeration == text {
                                        moderatedText = text
                                    } else {
                                        onDevice.clearModeration(message.id)
                                    }
                                }
                            }
                        } label: {
                            if running {
                                HStack(spacing: Theme.Spacing.small) {
                                    ProgressView().controlSize(.small)
                                    Text(stageLabel(onDevice.stage(for: message.id)))
                                }
                            } else {
                                Label("Get a recommendation", systemImage: "apple.intelligence")
                            }
                        }
                        .buttonStyle(.tbtGlass)
                        .disabled(busy || isActing)
                        Spacer()
                    }
                }
                if case .failed(let reason) = onDevice.stage(for: message.id), owns(.moderate) {
                    Text(reason)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.error)
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
                }
                Spacer(minLength: 0)
                Text(advice.source)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            caption("""
                Computed on this device. Submit it to the Operator so every reviewer \
                sees the same recommendation — nothing is sent until you do.
                """)
            if localVerdictIsSubmittable {
                HStack {
                    Spacer()
                    Button {
                        Task { await submitLocalVerdict(using: onDevice) }
                    } label: {
                        actionLabel("Submit recommendation", systemImage: "arrow.up.circle.fill")
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
        return moderatedText == operatorEnglish
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
        guard moderatedText == submitted, output?.recommendation != nil else {
            onDevice?.reset(message.id)
            drafts.clear(message.id)
            return
        }
        // Only the draft goes. `englishForModeration` then falls through to the
        // Operator's translation, which is this same text, so the verdict stays
        // matched rather than being dropped as stale.
        translationDraft = ""
    }

    /// Posts the on-device verdict to the Operator and, on success, clears the
    /// local result so it can't be submitted twice.
    private func submitLocalVerdict(using onDevice: OnDeviceReviewPipeline) async {
        guard localVerdictIsSubmittable,
              let output, let recommendation = output.recommendation else { return }
        let submitted = await store.submitModeration(
            message,
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
                caption("Review it, then submit it to the Operator — nothing is sent "
                        + "until you do.")
                HStack {
                    Spacer()
                    Button {
                        Task { await submitOnDeviceTranscript(output, using: onDevice) }
                    } label: {
                        actionLabel("Submit transcript", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.tbtGlass)
                    .disabled(onDevice.isRunning(message.id) || isActing)
                }
            }

            // The controls that produce this text belong with it. Kept as a
            // footer rather than a card of its own so the detail reads as one
            // step per card: transcript, translation, decision.
            if message.isReviewable, canRunTranscription { transcriptionRunFooter }
        }
    }

    /// False on a device with no Operator worker and no on-device transcriber —
    /// there is no button to show, so the footer (and its explanatory caption)
    /// would be dangling text.
    private var canRunTranscription: Bool {
        #if os(macOS)
        return true
        #else
        // A moderation-only pipeline exists but has no transcriber, so its
        // presence alone doesn't mean there's a button under this footer.
        return onDevice?.supportsTranscription == true
        #endif
    }

    @ViewBuilder
    private var transcriptionRunFooter: some View {
        Divider().overlay(Theme.Colors.textSecondary.opacity(0.2))

        if isQueued {
            Label("Queued for the local worker", systemImage: "clock.arrow.circlepath")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }

        #if os(macOS)
        // Only the Mac runs the Operator worker, so only the Mac can hand the
        // job off for a transcript that lands back on the Operator.
        HStack {
            Button {
                Task { await store.requestTranscription(message) }
            } label: {
                actionLabel(message.latestTranscription == nil
                            ? "Transcribe"
                            : "Re-run transcription",
                            systemImage: "waveform")
            }
            .buttonStyle(.tbtGlass)
            .disabled(isActing || isQueued)
            Spacer()
        }
        #else
        onDeviceTranscribeActions
        #endif

        if message.latestTranscription != nil {
            caption("Re-running keeps the old transcript; the newest one wins.")
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
            } else if !message.needsTranslation {
                // No transcript to translate yet: say so rather than render an
                // empty card.
                caption(message.transcriptionIsSilent
                        ? "Nothing to translate — the recording was silent."
                        : "Waiting on a transcript.")
            }

            if message.needsTranslation {
                onDeviceTranslateActions
                translationEditor
            }
        }
    }

    @ViewBuilder
    private var translationEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(message.translationFailed ? "Write the translation yourself" : "Your translation")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

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
                    actionLabel("Submit translation", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.tbtGlass)
                .disabled(isActing || translationDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Apple Intelligence entry point: re-transcribes the audio on this device,
    /// translates it, and pre-fills the draft. Never submits — the operator
    /// still reviews and taps Submit.
    @ViewBuilder
    private var onDeviceTranslateActions: some View {
        // `run` transcribes the audio before it translates, so this needs both
        // halves: a moderation-only pipeline would offer a button that always
        // fails at the first stage.
        if let onDevice, onDevice.supportsTranslation, onDevice.supportsTranscription {
            let stage = onDevice.stage(for: message.id)
            let busy = onDevice.isRunning(message.id)
            let running = busy && owns(.translate)

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack {
                    Button {
                        Task {
                            let draftBefore = translationDraft
                            let translation = await onDevice.run(for: message)
                            // `reset` can land between `run` returning and this
                            // continuation resuming, so re-check against the
                            // pipeline's current output rather than trusting the
                            // returned value — otherwise a cleared draft gets
                            // repopulated with a superseded translation.
                            guard let translation,
                                  onDevice.outputs[message.id]?.translation == translation
                            else { return }

                            // The editor stays enabled while this runs, so
                            // anything typed meanwhile is the operator's own
                            // work and outranks the generated text. The verdict
                            // describes the translation they didn't take, so it
                            // goes rather than sitting above their draft.
                            guard translationDraft == draftBefore else {
                                onDevice.clearModeration(message.id)
                                return
                            }

                            translationDraft = translation
                            // `run` moderates the translation it just produced,
                            // so the draft starts out as the moderated text —
                            // without this, editing it would leave that verdict
                            // on screen.
                            if onDevice.outputs[message.id]?.recommendation != nil {
                                moderatedText = translation
                            }
                        }
                    } label: {
                        if running {
                            HStack(spacing: Theme.Spacing.small) {
                                ProgressView().controlSize(.small)
                                Text(stageLabel(stage))
                            }
                        } else {
                            Label(message.translationFailed
                                  ? "Retry on device"
                                  : "Draft with Apple Intelligence",
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
                    // The audio itself *was* downloaded from blob storage, so
                    // don't claim nothing left the device — only that no content
                    // reached an AI service.
                    caption("Processed on this device — no audio or text was sent to an AI "
                            + "service. Review the draft before submitting.")
                }
            }
        }
    }

    // MARK: - Decision

    private var decisionCard: some View {
        card(title: "Decision", systemImage: "checkmark.seal") {
            if message.nextStep != .decision {
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

    /// iOS has no Operator worker, but it can still transcribe locally with
    /// Apple Intelligence. The transcript is shown first and only posted to the
    /// Operator on a deliberate Submit tap — never automatically, matching how
    /// translations pre-fill a draft.
    @ViewBuilder
    private var onDeviceTranscribeActions: some View {
        if let onDevice, onDevice.supportsTranscription {
            let stage = onDevice.stage(for: message.id)
            let busy = onDevice.isRunning(message.id)
            let running = busy && owns(.transcribe)

            HStack {
                Button {
                    Task { await onDevice.transcribeOnly(for: message) }
                } label: {
                    if running {
                        HStack(spacing: Theme.Spacing.small) {
                            ProgressView().controlSize(.small)
                            Text(stageLabel(stage))
                        }
                    } else {
                        Label("Transcribe on device", systemImage: "apple.intelligence")
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
