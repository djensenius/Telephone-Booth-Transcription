import SwiftUI
import TranscriptionAuth
import TranscriptionOperator
import TranscriptionReview

/// The review queue: the operator's primary surface. Surfaces messages whose
/// transcription still needs translation and messages awaiting a moderation
/// decision, alongside the AI's recommendation, and lets the operator act:
/// submit a translation, or approve / reject a message.
struct ReviewView: View {
    @EnvironmentObject private var host: ServerHost
    @State private var auth = AuthManager.shared
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var store = ReviewStore(
        client: HTTPOperatorReviewClient(tokenProvider: AuthBearerAdapter())
    )
    /// Nil when this device can't transcribe on-device — the entry point is
    /// then hidden rather than offered and always failing.
    ///
    /// Probed asynchronously rather than set up front: the capability check is
    /// locale-aware and `SpeechTranscriber.supportedLocale(equivalentTo:)` is
    /// `async`. Re-probed when the view appears, because Apple Intelligence can
    /// be enabled, or a model finish downloading, while the app stays open. A
    /// use-time recheck can't rescue that case, because with no pipeline there
    /// is no button to press in the first place.
    @State private var onDevice: OnDeviceReviewPipeline?
    /// Bumped on every appearance to re-run the capability probe. `.task(id:)`
    /// gives the probe a task to run in (and cancellation on disappear), which
    /// a synchronous `.onAppear` can't.
    @State private var probeGeneration = 0

    var body: some View {
        Group {
            if auth.isSignedIn {
                queue
            } else {
                signedOut
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: auth.isSignedIn) {
            store.transcriptionRerunner = host
            if auth.isSignedIn {
                await store.poll()
            } else {
                // This view outlives the session, so locally generated
                // transcripts would otherwise survive into the next sign-in.
                // Pruning everything also supersedes any run still in flight.
                onDevice?.prune(keeping: [])
            }
        }
        .onAppear { probeGeneration &+= 1 }
        .task(id: probeGeneration) { await refreshOnDeviceCapability() }
    }

    /// Re-probes Apple Intelligence when the queue appears, so enabling it (or
    /// finishing a model download) while the app is running surfaces the
    /// affordance without a relaunch.
    ///
    /// Only ever upgrades, and never while work is outstanding: swapping the
    /// pipeline would strand a running task's result on the discarded instance,
    /// where nothing observes it. The next appearance picks the upgrade up.
    private func refreshOnDeviceCapability() async {
        guard let existing = onDevice else {
            let made = await OnDeviceReviewPipeline.makeAppleIntelligence()
            // A concurrent probe may have won the race while this one awaited.
            if onDevice == nil { onDevice = made }
            return
        }
        guard existing.supportsTranslation == false else { return }
        guard visibleMessageIDs.allSatisfy({ !existing.isRunning($0) }) else { return }
        guard let refreshed = await OnDeviceReviewPipeline.makeAppleIntelligence(),
              refreshed.supportsTranslation else { return }
        // The probe suspended; re-check that the pipeline it would replace is
        // still the idle one it was chosen for.
        guard onDevice === existing,
              visibleMessageIDs.allSatisfy({ !existing.isRunning($0) }) else { return }
        onDevice = refreshed
    }

    private var signedOut: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("Sign in to review messages")
                .font(Theme.Fonts.headerLarge())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Sign in with your Operator account to load the review queue.")
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                Task { await signIn() }
            } label: {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            .buttonStyle(.tbtGlass)
            .disabled(isSigningIn)

            if let signInError {
                Text(signInError)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            try await auth.signInWithOIDC()
        } catch AuthError.cancelled {
            // User dismissed the sheet; not an error worth surfacing.
        } catch {
            signInError = error.localizedDescription
        }
    }

    private var queue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                header

                if case .failed(let message) = store.state {
                    banner(message, systemImage: "exclamationmark.triangle.fill", tint: Theme.Colors.warning)
                }

                if let actionError = store.actionError {
                    banner(actionError, systemImage: "xmark.octagon.fill", tint: Theme.Colors.error)
                }

                bucket(
                    title: "Needs transcription",
                    systemImage: "waveform",
                    messages: store.awaitingTranscription,
                    emptyText: "Every message in the queue has a transcription.",
                    kind: .transcription
                )

                bucket(
                    title: "Needs translation",
                    systemImage: "character.book.closed",
                    messages: store.awaitingTranslation,
                    emptyText: "Every transcription is translated.",
                    kind: .translation
                )

                bucket(
                    title: "Awaiting moderation",
                    systemImage: "checklist",
                    messages: store.awaitingModeration,
                    emptyText: "No messages waiting on a decision.",
                    kind: .moderation
                )

                bucket(
                    title: "Transcription history",
                    systemImage: "arrow.clockwise.circle",
                    messages: store.withTranscriptionHistory,
                    emptyText: "No message has been transcribed yet.",
                    kind: .retranscription
                )
            }
            .padding(Theme.Spacing.large)
        }
        .refreshable { await store.refresh() }
        .onChange(of: visibleMessageIDs) { _, ids in
            // Transcripts and translations live in the pipeline until pruned;
            // drop anything that has left the queue.
            onDevice?.prune(keeping: ids)
        }
    }

    /// Every message id currently rendered in any bucket.
    private var visibleMessageIDs: Set<String> {
        var ids = Set(store.awaitingTranscription.map(\.id))
        ids.formUnion(store.awaitingTranslation.map(\.id))
        ids.formUnion(store.awaitingModeration.map(\.id))
        ids.formUnion(store.withTranscriptionHistory.map(\.id))
        return ids
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review")
                    .font(Theme.Fonts.headerXL())
                    .foregroundStyle(Theme.Colors.textPrimary)
                if let updated = store.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.state == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.tbtGlass)
            .disabled(store.state == .loading)
        }
    }

    @ViewBuilder
    private func bucket(
        title: String,
        systemImage: String,
        messages: [Message],
        emptyText: String,
        kind: ReviewRow.Kind
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label("\(title) (\(messages.count))", systemImage: systemImage)
                .font(Theme.Fonts.headerLarge())
                // Header text stays high-contrast; the coloured spine carries
                // the bucket's accent.
                .foregroundStyle(Theme.Colors.textPrimary)

            if let subtitle = kind.subtitle {
                Text(subtitle)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            if messages.isEmpty {
                Text(emptyText)
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Spacing.small)
            } else {
                ForEach(messages) { message in
                    ReviewRow(message: message, kind: kind, store: store, onDevice: onDevice)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .overlay(alignment: .leading) {
            // A coloured spine keeps the "not transcribed yet" queue visually
            // distinct from the deliberate re-run set.
            RoundedRectangle(cornerRadius: 2)
                .fill(kind.accent.opacity(0.5))
                .frame(width: 3)
                .padding(.vertical, Theme.Spacing.small)
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Fonts.bodyMedium)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.medium)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

private struct ReviewRow: View {
    enum Kind {
        case transcription, translation, moderation, retranscription

        /// Tint used for the bucket header and spine.
        var accent: Color {
            switch self {
            case .transcription: return Theme.Colors.warning
            case .translation, .moderation: return Theme.Colors.textPrimary
            case .retranscription: return Theme.Colors.info
            }
        }

        var subtitle: String? {
            switch self {
            case .transcription:
                return "Reviewable messages the AI hasn’t transcribed yet."
            case .retranscription:
                return "Transcribed, in progress, or failed. Re-running keeps the old transcript; "
                    + "the newest one wins."
            case .translation, .moderation:
                return nil
            }
        }
    }

    let message: Message
    let kind: Kind
    let store: ReviewStore
    let onDevice: OnDeviceReviewPipeline?

    @State private var translationDraft = ""
    @State private var notesDraft = ""

    private var isActing: Bool { store.isActing(on: message.id) }
    private var isQueued: Bool { store.isTranscriptionQueued(message.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                StatusPill(text: message.status.displayName, tint: statusTint)
                StatusPill(text: transcriptionStateText, tint: transcriptionStateTint)
                if let recommendation = message.latestModeration?.recommendation {
                    StatusPill(
                        text: "AI: \(recommendation.displayName)",
                        tint: recommendationTint(recommendation)
                    )
                }
                Spacer()
                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Text(transcriptText)
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(4)

            if let reason = message.latestModeration?.reasonSummary, !reason.isEmpty {
                Text(reason)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
            }

            switch kind {
            case .transcription: transcriptionActions(title: "Transcribe")
            case .retranscription: transcriptionActions(title: "Re-run transcription")
            case .translation: translationActions
            case .moderation: moderationActions
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.tertiaryBackground.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    @ViewBuilder
    private func transcriptionActions(title: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                if isQueued {
                    Label("Queued for the local worker", systemImage: "clock.arrow.circlepath")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                #if os(macOS)
                // Only the Mac runs the Operator worker, so only the Mac can
                // hand the job off for a transcript that lands back on the
                // Operator. iOS transcribes on-device instead (below).
                Button {
                    Task { await store.requestTranscription(message) }
                } label: {
                    actionLabel(title, systemImage: "waveform")
                }
                .buttonStyle(.tbtGlass)
                .disabled(isActing || isQueued)
                #endif
            }

            #if !os(macOS)
            onDeviceTranscribeActions
            #endif
        }
    }

    /// iOS has no Operator worker, but it can still transcribe locally with
    /// Apple Intelligence. The transcript is shown first and only posted to the
    /// Operator on a deliberate Submit tap — never automatically, matching how
    /// translations pre-fill a draft.
    @ViewBuilder
    private var onDeviceTranscribeActions: some View {
        if let onDevice {
            let stage = onDevice.stage(for: message.id)
            let running = onDevice.isRunning(message.id)

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
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
                    .disabled(running || isActing)
                    Spacer()
                }

                if case .failed(let reason) = stage {
                    Text(reason)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.error)
                }

                if let output = onDevice.outputs[message.id] {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        if output.transcript.isEmpty {
                            Text("No speech detected.")
                                .font(Theme.Fonts.bodyMedium)
                                .italic()
                                .foregroundStyle(Theme.Colors.textSecondary)
                        } else {
                            Text(output.transcript)
                                .font(Theme.Fonts.bodyMedium)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .textSelection(.enabled)
                        }
                        Text("Transcribed on this device. Review it, then submit it "
                             + "to the Operator — nothing is sent until you do.")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)

                        HStack {
                            Spacer()
                            Button {
                                Task { await submitOnDeviceTranscript(output, using: onDevice) }
                            } label: {
                                actionLabel("Submit transcript", systemImage: "arrow.up.circle.fill")
                            }
                            .buttonStyle(.tbtGlass)
                            .disabled(running || isActing)
                        }
                    }
                }
            }
        }
    }

    /// Posts a locally produced transcript to the Operator and, on success,
    /// clears the on-device result so the row can't be submitted twice.
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
        if submitted { onDevice.reset(message.id) }
    }

    @ViewBuilder
    private var translationActions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            onDeviceActions

            TextField("English translation", text: $translationDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .font(Theme.Fonts.bodyMedium)
                .padding(Theme.Spacing.small)
                .background(Theme.Colors.secondaryBackground.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .disabled(isActing)
                .onChange(of: message.latestTranscription?.id) {
                    // A new transcription replaced the one being translated;
                    // drop the draft so it can't be applied to the wrong source.
                    translationDraft = ""
                    onDevice?.reset(message.id)
                }

            HStack {
                Spacer()
                Button {
                    let text = translationDraft
                    Task { await store.submitTranslation(message, text: text) }
                } label: {
                    actionLabel("Submit translation", systemImage: "character.book.closed.fill")
                }
                .buttonStyle(.tbtGlass)
                .disabled(isActing || translationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Apple Intelligence entry point: re-transcribes the message audio on this
    /// device, translates it, and pre-fills the draft below. Never submits —
    /// the operator still reviews and taps Submit.
    @ViewBuilder
    private var onDeviceActions: some View {
        if let onDevice, onDevice.supportsTranslation {
            let stage = onDevice.stage(for: message.id)
            let running = onDevice.isRunning(message.id)

            HStack(spacing: Theme.Spacing.small) {
                Button {
                    Task {
                        let translation = await onDevice.run(for: message)
                        // `reset` can land between `run` returning and this
                        // continuation resuming, so re-check against the
                        // pipeline's current output rather than trusting the
                        // returned value — otherwise a cleared draft gets
                        // repopulated with a superseded translation.
                        if let translation,
                           onDevice.outputs[message.id]?.translation == translation {
                            translationDraft = translation
                        }
                    }
                } label: {
                    if running {
                        HStack(spacing: Theme.Spacing.small) {
                            ProgressView().controlSize(.small)
                            Text(stageLabel(stage))
                        }
                    } else {
                        Label("Transcribe & translate on device", systemImage: "apple.intelligence")
                    }
                }
                .buttonStyle(.tbtGlass)
                .disabled(running || isActing)
                Spacer()
            }

            if case .failed(let reason) = stage {
                Text(reason)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.error)
            }

            if let output = onDevice.outputs[message.id] {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-device transcript: \(output.transcript)")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(3)
                    if let recommendation = output.recommendation {
                        Text("On-device moderation: \(recommendation)"
                             + ((output.flagged ?? false) ? " (flagged)" : ""))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    // The audio itself *was* downloaded from blob storage, so
                    // don't claim nothing left the device — only that no
                    // content reached an AI processor.
                    Text("Processed on this device — no audio or text was sent "
                         + "to an AI service. Review the draft before submitting.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
    }

    private func stageLabel(_ stage: OnDeviceReviewPipeline.Stage) -> String {
        switch stage {
        case .fetchingAndTranscribing: return "Transcribing…"
        case .translating: return "Translating…"
        case .moderating: return "Checking…"
        default: return "Working…"
        }
    }

    @ViewBuilder
    private var moderationActions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField("Notes (optional)", text: $notesDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .font(Theme.Fonts.caption)
                .padding(Theme.Spacing.small)
                .background(Theme.Colors.secondaryBackground.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .disabled(isActing)

            HStack(spacing: Theme.Spacing.small) {
                Spacer()
                Button {
                    let notes = notesDraft
                    Task { await store.decide(message, .reject, notes: notes) }
                } label: {
                    actionLabel("Reject", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.tbtGlass)
                .tint(Theme.Colors.error)
                .disabled(isActing)

                Button {
                    let notes = notesDraft
                    Task { await store.decide(message, .approve, notes: notes) }
                } label: {
                    actionLabel("Approve", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.tbtGlass)
                .tint(Theme.Colors.success)
                .disabled(isActing)
            }
        }
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        if isActing {
            ProgressView().controlSize(.small)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private var transcriptText: String {
        if let text = message.latestTranscription?.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return message.transcriptionIsSilent
            ? "Silent recording — the transcription returned no speech."
            : "No transcription yet."
    }

    /// Distinguishes "never transcribed" from "transcribed but silent" so an
    /// operator can tell an unenriched message from an empty one.
    private var transcriptionStateText: String {
        if message.transcriptionIsSilent { return "Silent" }
        if message.hasSucceededTranscription { return "Transcribed" }
        if message.transcriptionFailed { return "Transcription failed" }
        if message.transcriptionIsUnfinished { return "Transcribing…" }
        return "No transcription"
    }

    /// These pills use the primary text colour over a neutral fill rather than a
    /// low-contrast semantic tint; the bucket a row sits in already carries the
    /// meaning, so legibility wins here.
    private var transcriptionStateTint: Color { Theme.Colors.textPrimary }

    private var statusTint: Color {
        switch message.status {
        case .approved: return Theme.Colors.success
        case .rejected: return Theme.Colors.error
        case .pending, .received: return Theme.Colors.warning
        default: return Theme.Colors.info
        }
    }

    private func recommendationTint(_ recommendation: ModerationRecommendation) -> Color {
        switch recommendation {
        case .approve: return Theme.Colors.success
        case .reject: return Theme.Colors.error
        case .review: return Theme.Colors.warning
        case .unknown: return Theme.Colors.info
        }
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Theme.Fonts.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
