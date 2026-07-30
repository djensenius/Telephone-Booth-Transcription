import SwiftUI
import TranscriptionAuth
import TranscriptionOperator
import TranscriptionReview

/// The review queue: the operator's primary surface.
///
/// One list of messages, newest first, narrowed by a filter bar — rather than
/// the previous stacked buckets, which showed the same message up to four times
/// and buried every control in the list itself (issue #79). Selecting a message
/// opens the detail view, where the full text and all actions live.
struct ReviewView: View {
    @EnvironmentObject private var host: ServerHost
    @State private var auth = AuthManager.shared
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var store = ReviewStore(
        client: DemoMode.isActive
            ? DemoOperatorReviewClient()
            : HTTPOperatorReviewClient(tokenProvider: AuthBearerAdapter())
    )
    @State private var filter: ReviewStore.Filter = .needsAttention
    @State private var selectedID: String?
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
    /// Owned here, not by the detail view, so unsent drafts survive a selection
    /// change or a navigation pop.
    @State private var drafts = ReviewDraftStore()
    /// Bumped on every appearance to re-run the capability probe. `.task(id:)`
    /// gives the probe a task to run in (and cancellation on disappear), which
    /// a synchronous `.onAppear` can't.
    @State private var probeGeneration = 0

    var body: some View {
        Group {
            switch authState {
            case .signedIn:
                queue
            case .unknown:
                restoringSession
            case .signedOut:
                signedOut
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: authState) {
            store.transcriptionRerunner = host
            switch authState {
            case .signedIn:
                await store.poll()
            case .unknown:
                // Still restoring: the session may well come back, so hold on
                // to local work rather than pruning it.
                break
            case .signedOut:
                // This view outlives the session, so locally generated
                // transcripts would otherwise survive into the next sign-in.
                // Pruning everything also supersedes any run still in flight.
                onDevice?.prune(keeping: [])
                drafts.prune(keeping: [])
                selectedID = nil
            }
        }
        .onAppear { probeGeneration &+= 1 }
        .task(id: probeGeneration) { await refreshOnDeviceCapability() }
    }

    /// Demo mode serves a canned queue, so it stands in for a session — Review
    /// is otherwise unreachable without a live Operator, and therefore
    /// impossible to screenshot or preview.
    private var authState: AuthManager.AuthState {
        DemoMode.isActive ? .signedIn : auth.authState
    }

    /// Shown while a stored session is being exchanged for a fresh access
    /// token. Distinct from `signedOut`: offering a Sign In button here would
    /// push the operator through a browser flow they don't need.
    private var restoringSession: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ProgressView()
            Text("Restoring your session…")
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Signed out

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

    // MARK: - Queue

    private var queue: some View {
        platformQueue
            .onChange(of: activeMessageIDs) { _, ids in
                // Transcripts and translations live in the pipeline until
                // pruned; drop anything that no longer needs work. Keyed to the
                // *active* set rather than every fetched message: a decided
                // message stays in the queue for the All filter, so pruning on
                // the full set would keep its text resident until it fell out
                // of the fetch window.
                onDevice?.prune(keeping: ids)
                drafts.prune(keeping: ids)
            }
            .onChange(of: transcriptionSnapshots) { old, new in
                // A poll can replace the transcript of a row the operator isn't
                // looking at. Its on-device output was computed from the
                // superseded text, so drop it here rather than in the detail
                // view, which only sees the message it has open.
                //
                // Keyed to the text rather than the transcription id: the
                // Operator finalizes a pending row *in place*, so the id can
                // stay put while the text it stands for changes completely.
                for (id, snapshot) in new where old[id] != snapshot {
                    onDevice?.reset(id)
                    // The detail view clears its own drafts on the same signal,
                    // but only for the message it has open.
                    drafts.clear(id)
                }
            }
    }

    /// Every message id currently held by the store.
    private var visibleMessageIDs: Set<String> {
        Set(store.messages.map(\.id))
    }

    /// The messages still waiting on the operator — the only ones whose local
    /// transcripts and translations are still worth holding on to.
    private var activeMessageIDs: Set<String> {
        Set(store.messages.filter(\.needsAttention).map(\.id))
    }

    /// What the Operator currently holds for each message, as a snapshot that
    /// changes whenever the authoritative text does — a new transcription row,
    /// a pending one finalized in place, or a translation arriving. Messages
    /// with nothing on record are omitted, so local work on a message the
    /// Operator hasn't transcribed yet is left alone until it lands.
    private var transcriptionSnapshots: [String: String] {
        store.messages.reduce(into: [:]) { result, message in
            guard let transcription = message.latestTranscription else { return }
            result[message.id] = [
                transcription.id,
                transcription.text ?? "",
                transcription.translatedText ?? "",
            ].joined(separator: "\u{1F}")
        }
    }

    private var filtered: [Message] { store.messages(for: filter) }

    #if os(macOS)
    /// List on the left, the selected message on the right. Triage on a Mac is
    /// a two-pane job: the operator keeps their place in the queue while acting.
    private var platformQueue: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                listHeader
                messageList
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)

            Divider().overlay(Theme.Colors.textSecondary.opacity(0.2))

            Group {
                if let selectedID, let message = store.message(id: selectedID) {
                    ReviewDetailView(message: message, store: store, onDevice: onDevice, drafts: drafts)
                        .id(message.id)
                } else {
                    detailPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            // Keep a selection alive as the list churns under it, but only
            // auto-select when nothing is chosen — never steal a selection the
            // operator made. A selection that no longer resolves in the store
            // counts as nothing chosen: the message has left the queue, and
            // holding the id would pin the detail to the placeholder for good.
            if selectedID.flatMap({ store.message(id: $0) }) == nil {
                selectedID = ids.first
            }
        }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: "checklist")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("Select a message")
                .font(Theme.Fonts.headerLarge())
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var messageList: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            List(selection: $selectedID) {
                ForEach(filtered) { message in
                    row(message)
                        .tag(message.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .refreshable { await store.refresh() }
        }
    }
    #else
    /// iOS pushes to the detail instead: there isn't room for two panes, and a
    /// push keeps the queue one back-swipe away.
    private var platformQueue: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                listHeader
                if filtered.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filtered) { message in
                            NavigationLink(value: message.id) {
                                row(message)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await store.refresh() }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let message = store.message(id: id) {
                    ReviewDetailView(message: message, store: store, onDevice: onDevice, drafts: drafts)
                        .id(message.id)
                        .navigationTitle("Message")
                        .navigationBarTitleDisplayMode(.inline)
                        .background(ThemedWindowBackground())
                }
            }
        }
    }
    #endif

    private func row(_ message: Message) -> some View {
        ReviewMessageRow(message: message, onDeviceOutput: onDevice?.outputs[message.id])
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if message.awaitingModerationDecision {
                    Button(role: .destructive) {
                        Task { await store.decide(message, .reject) }
                    } label: {
                        Label("Reject", systemImage: "xmark.circle.fill")
                    }
                    Button {
                        Task { await store.decide(message, .approve) }
                    } label: {
                        Label("Approve", systemImage: "checkmark.circle.fill")
                    }
                    .tint(Theme.Colors.success)
                }
            }
    }

    // MARK: - Header

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
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
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.tbtGlass)
                .disabled(store.state == .loading)
                .accessibilityLabel("Refresh")
            }

            filterBar

            if case .failed(let message) = store.state {
                banner(message, systemImage: "exclamationmark.triangle.fill",
                       tint: Theme.Colors.warning)
            }

            // Rows can be approved or rejected by swiping, without ever opening
            // the detail, so a failure has to be reportable from here too. On
            // iOS the detail is a pushed screen and this header is never
            // simultaneously visible, so the detail carries its own copy; on
            // macOS the two sit side by side and this one covers both.
            if let actionError = store.actionError {
                banner(actionError, systemImage: "xmark.octagon.fill", tint: Theme.Colors.error)
            }
        }
        .padding(Theme.Spacing.large)
    }

    /// Horizontally scrolling tabs. A segmented `Picker` was rejected: five
    /// segments with counts don't fit an iPhone width without truncating to
    /// uselessness.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(ReviewStore.Filter.allCases) { item in
                    filterTab(item)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterTab(_ item: ReviewStore.Filter) -> some View {
        let selected = filter == item
        let count = store.count(for: item)
        return Button {
            filter = item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 11))
                Text(item.title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            selected
                                ? Theme.Colors.onAccent.opacity(0.18)
                                : Theme.Colors.textSecondary.opacity(0.2),
                            in: Capsule()
                        )
                }
            }
            .font(Theme.Fonts.bodyMedium.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textPrimary)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, 6)
            .background(
                selected ? Theme.Colors.accent : Theme.Colors.tertiaryBackground.opacity(0.5),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: filter.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(filter.emptyText)
                .font(Theme.Fonts.bodyLarge)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.large)
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Fonts.bodyMedium)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.medium)
            .background(tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}
