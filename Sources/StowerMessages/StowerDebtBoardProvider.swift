import Foundation
import os

/// The production `StowerDebtBoardProviding` actor.
///
/// Orchestrates: a startup availability gate → a shared snapshot reader (rebuilt
/// each refresh) → states with last-act GUIDs → trusted cached language-model
/// verdicts → the two policies → a judged-only board. The load path never reaches
/// a model and serves
/// only conversations a trusted verdict is cached for; the background
/// `refreshJudgments` is the only model caller and the only cache writer. The
/// cache is the trust boundary and is disposable — any cache fault is a miss,
/// re-judged later (M9). The judging + timeout mechanics live in the matching
/// `extension` file.
public actor StowerDebtBoardProvider: StowerDebtBoardProviding {
    internal let readerFactory: @Sendable () throws -> StowerConversationFactsReading

    /// The bookmark `readerFactory()` would open right now, read on every reader
    /// use so a re-grant can invalidate the cached reader.
    ///
    /// `readerFactory()` re-reads the stored bookmark on each call, but the reader
    /// it produces is cached (see `activeReader`) — so without this, a reader
    /// opened from an OLD bookmark would outlive a re-grant and keep serving the
    /// previously granted folder until a background refresh happened to rebuild
    /// it. Comparing this against the bookmark the cached reader was opened from
    /// is what makes `init`'s documented "takes effect on the very next
    /// load/refresh" true for a RE-grant, not only for a first grant.
    ///
    /// `nil` for sources that cannot change under the provider (the DEBUG demo
    /// source, test doubles), which therefore never invalidate. Bookmark `Data`
    /// is compared bytewise, so a re-minted bookmark for the SAME folder (see
    /// `onBookmarkRefreshed`) also invalidates — one extra reader open, never a
    /// missed one. Erring toward rebuilding is the only safe polarity: a spurious
    /// rebuild costs a snapshot copy, a missed one serves the wrong folder's data.
    internal let readerSourceBookmark: @Sendable () -> Data?

    internal let resolveLanguageModelJudge: @Sendable () -> StowerReplyExpectationJudge?
    internal let modelAvailabilityResolver: @Sendable () async -> StowerModelAvailability
    internal let cache: StowerReplyVerdictCaching?
    internal let windowDays: Int
    private var refreshInFlight = false

    /// The shared snapshot reader, reused across loads and thread taps.
    ///
    /// Opening a reader copies `chat.db` and runs a full integrity check — too
    /// expensive to repeat on every board load and every thread tap-through. One
    /// reader is opened lazily and reused; `refreshJudgments` rebuilds it so each
    /// background pass reads current messages. Between refreshes the board is
    /// served from cached verdicts anyway, so reuse adds no staleness the cache
    /// did not already have. The actor serializes access; a failed rebuild keeps
    /// the last good reader.
    ///
    /// Reuse is scoped to ONE grant: it is only "no staleness the cache did not
    /// already have" while the reader's bookmark is still the current one, so
    /// `sharedReader()` re-opens when `readerSourceBookmark()` no longer matches
    /// `activeReaderBookmark`.
    private var activeReader: StowerConversationFactsReading?

    /// The bookmark `activeReader` was opened from, or `nil` when it came from a
    /// source with no bookmark (DEBUG demo, tests) or no reader is open yet.
    private var activeReaderBookmark: Data?

    /// Per-record cap on one judge call so a hung model can't stall refresh.
    ///
    /// On timeout the record is counted `failed` and retried next pass. Lives on
    /// the provider (its refresh enforces the cap) — not on the `@available`
    /// judge, which the non-gated provider couldn't reference without an
    /// availability dance. Tune to real on-device FM latency.
    internal static let perRecordTimeout: Duration = .seconds(20)

    internal static let logger = Logger(subsystem: "com.stower.messages", category: "reply-refresh")

    /// The default verdict-cache location under
    /// `Application Support/<folderName>`.
    ///
    /// `nil` when Application Support itself cannot be resolved or created, or
    /// when `folderName` is not a single, safe path component (empty, contains
    /// `/`, or is `.`/`..`).
    ///
    /// - Parameter folderName: The build-variant Application Support subfolder
    ///   (e.g. `"Stower"`, `"StowerDebug"`), supplied by the caller so this
    ///   engine-side type never has to know about `StowerEnvironment` itself.
    /// - Returns: The resolved `reply-verdicts.sqlite` URL, or `nil` per the cases
    ///   above.
    public static func cacheURL(inFolder folderName: String) -> URL? {
        guard !folderName.isEmpty, !folderName.contains("/"), folderName != "..", folderName != "."
        else {
            return nil
        }
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else {
            return nil
        }
        return
            base
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(StowerReplyVerdictCache.fileName)
    }

    /// Creates a provider over a security-scoped bookmark for the Messages folder.
    ///
    /// - Parameters:
    ///   - loadMessagesAccessBookmark: Reads the currently stored bookmark
    ///     `Data`, or `nil` if none is stored. Never captured as a fixed value:
    ///     it is invoked by `readerFactory()` whenever a reader is opened, AND
    ///     on every `sharedReader()` to detect that the stored bookmark changed
    ///     under a cached reader. So a bookmark granted — or RE-granted for a
    ///     different folder — after this provider was constructed takes effect
    ///     on the very next load/refresh, not only after a relaunch.
    ///   - contactsResolver: The handle-to-name resolver; denial degrades to raw
    ///     handles (M4), never an error.
    ///   - onBookmarkRefreshed: Called with freshly re-created bookmark `Data`
    ///     when the stored bookmark resolved but was stale. This provider never
    ///     persists it itself — persistence is the caller's (UI's)
    ///     responsibility.
    ///   - cacheURL: Where to persist trusted verdicts; a fault here leaves the
    ///     cache absent and the board empty until refresh can rebuild it (M9).
    ///   - windowDays: How far back to read facts.
    public init(
        loadMessagesAccessBookmark: @escaping @Sendable () -> Data?,
        contactsResolver: StowerContactsResolver = .live(),
        onBookmarkRefreshed: @escaping @Sendable (Data) -> Void = { _ in },
        cacheURL: URL?,
        windowDays: Int = 180
    ) {
        readerFactory = {
            try StowerChatDatabaseReader(
                loadMessagesAccessBookmark: loadMessagesAccessBookmark,
                contactsResolver: contactsResolver,
                onBookmarkRefreshed: onBookmarkRefreshed
            )
        }
        readerSourceBookmark = loadMessagesAccessBookmark
        // Resolve the system judge per call, not once at init: a provider built
        // while Apple Intelligence is still downloading picks the model up when it
        // comes online.
        resolveLanguageModelJudge = { Self.makeSystemLanguageModelJudge() }
        modelAvailabilityResolver = { StowerLanguageModelAvailability.current() }
        cache = cacheURL.flatMap(Self.openCache)
        self.windowDays = windowDays
    }

    #if DEBUG
        /// Creates a provider directly over `demoSourceURL`, bypassing the
        /// bookmark/security-scope machinery entirely.
        ///
        /// DEBUG-only: mirrors `StowerChatDatabaseReader`'s demo initializer so
        /// dev/demo builds can point the board at a curated database without a
        /// picker or a real grant.
        public init(
            demoSourceURL: URL,
            contactsResolver: StowerContactsResolver = .live(),
            cacheURL: URL?,
            windowDays: Int = 180
        ) {
            readerFactory = {
                try StowerChatDatabaseReader(
                    demoSourceURL: demoSourceURL,
                    contactsResolver: contactsResolver
                )
            }
            // A fixed `demoSourceURL` cannot change under the provider, so the
            // reader never needs re-opening for a source change.
            readerSourceBookmark = { nil }
            resolveLanguageModelJudge = { Self.makeSystemLanguageModelJudge() }
            modelAvailabilityResolver = { StowerLanguageModelAvailability.current() }
            cache = cacheURL.flatMap(Self.openCache)
            self.windowDays = windowDays
        }
    #endif

    /// Creates a provider from injected dependencies, for tests.
    ///
    /// A `languageModelJudgeResolver` models availability changing over time — it
    /// is consulted on each pass. `modelAvailabilityResolver` injects each typed
    /// availability state so tests assert load/refresh route before touching the
    /// reader. Availability is no longer inferred from a nil judge.
    /// `readerSourceBookmark` defaults to a source that never changes; a test
    /// models a re-grant by returning different `Data` from it.
    internal init(
        readerFactory: @escaping @Sendable () throws -> StowerConversationFactsReading,
        readerSourceBookmark: @escaping @Sendable () -> Data? = { nil },
        languageModelJudge: StowerReplyExpectationJudge?,
        cache: StowerReplyVerdictCaching?,
        windowDays: Int = 180,
        languageModelJudgeResolver: (@Sendable () -> StowerReplyExpectationJudge?)? = nil,
        modelAvailabilityResolver: @escaping @Sendable () async -> StowerModelAvailability = {
            .available
        }
    ) {
        self.readerFactory = readerFactory
        self.readerSourceBookmark = readerSourceBookmark
        resolveLanguageModelJudge = languageModelJudgeResolver ?? { languageModelJudge }
        self.modelAvailabilityResolver = modelAvailabilityResolver
        self.cache = cache
        self.windowDays = windowDays
    }

    /// Whether the on-device language model can serve verdicts right now.
    public func modelAvailability() async -> StowerModelAvailability {
        await modelAvailabilityResolver()
    }

    /// The shared reader, opening one on first use — and re-opening it when the
    /// grant it was opened from is no longer current (load / thread-tap path).
    ///
    /// The re-open is what keeps a re-grant honest: the load path (both the
    /// startup probe and the live board) comes through here, so a user who picks
    /// a different Messages folder reads from it on the very next load rather
    /// than waiting for a background `refreshJudgments` pass to rebuild the
    /// reader.
    private func sharedReader() throws -> StowerConversationFactsReading {
        let bookmark = readerSourceBookmark()
        if let activeReader, bookmark == activeReaderBookmark {
            return activeReader
        }
        return try openedReader(bookmark: bookmark)
    }

    /// Rebuilds the shared reader so a refresh pass reads current messages.
    ///
    /// Records the bookmark it opened from like every other open does. Skipping
    /// that would leave `activeReaderBookmark` stale behind a fresh reader, so
    /// every later `sharedReader()` would mismatch and re-open — a `chat.db` copy
    /// per load and per thread tap.
    private func refreshedReader() throws -> StowerConversationFactsReading {
        try openedReader(bookmark: readerSourceBookmark())
    }

    /// Opens a reader and records the bookmark it came from, so a later
    /// `sharedReader()` can tell whether it still matches the current grant.
    ///
    /// The bookmark is read BEFORE the open (by the caller) and recorded after,
    /// so a grant landing during the open records the older value and re-opens
    /// next time — the conservative direction. A throwing open leaves both
    /// fields untouched, keeping the last good reader.
    private func openedReader(bookmark: Data?) throws -> StowerConversationFactsReading {
        let reader = try readerFactory()
        activeReader = reader
        activeReaderBookmark = bookmark
        return reader
    }

    /// Builds the judged-only board from the shared snapshot plus trusted verdicts.
    public func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard {
        // A threshold past the read window could only ever match unread history,
        // so it would silently return an empty board. Fail loud: widen windowDays.
        guard config.unansweredForDays <= windowDays else {
            throw StowerMessagesError.invalidArgument(
                "unansweredForDays (\(config.unansweredForDays)) must not exceed the provider's "
                    + "windowDays (\(windowDays)); widen the read window to cover the threshold."
            )
        }
        // Availability is checked AFTER config bounds but BEFORE the reader, so an
        // unsupported device never opens the private database. A supported device
        // still surfaces messages-access / source errors normally.
        if case .unavailable(let reason) = await modelAvailabilityResolver() {
            throw StowerMessagesError.languageModelUnavailable(reason)
        }
        // Resolve the judge BEFORE opening the reader. Availability passed above but
        // the concrete judge could not be built (model evicted between the two
        // resolves, or a construction fault). Fail loud and symmetric with the
        // availability gate — and before the side effect of opening (copying)
        // chat.db — never a silent empty board the user reads as "all caught up".
        guard let judge = resolveLanguageModelJudge() else {
            throw StowerMessagesError.languageModelUnavailable(.modelNotReady)
        }
        let reader = try sharedReader()
        let records = try await reader.conversationStateRecords(windowDays: windowDays, now: now)
        let judged = await judgedConversations(records: records, judge: judge)
        let neglected = StowerNoReplyPolicy.neglected(
            from: judged,
            unansweredForDays: config.unansweredForDays,
            minimumReciprocity: config.minimumReciprocity,
            now: now
        )
        let ghosted = StowerGhostedPolicy.ghosted(
            from: judged,
            unansweredForDays: config.unansweredForDays,
            minimumReciprocity: config.minimumReciprocity,
            ghostGateThreshold: config.ghostGateThreshold,
            now: now
        )
        return StowerDebtBoard(neglected: neglected, ghosted: ghosted)
    }

    /// Returns the newest `limit` messages of one chat, ordered oldest-first for
    /// display, for a tap-through thread view.
    public func recentMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage] {
        let reader = try sharedReader()
        return try await reader.threadMessages(chatID: chatID, limit: limit)
    }

    /// Judges un-cached conversations with the model and backfills the cache.
    public func refreshJudgments(
        config: StowerDebtConfig,
        now: Date
    ) async throws -> StowerRefreshSummary? {
        // Single-flight FIRST, before availability: a coalesced caller always gets
        // `nil`, even if availability changed while a pass was in flight. `nil`
        // means exactly "coalesced" — never a `0/0/0` that would clear loading.
        guard !refreshInFlight else { return nil }
        refreshInFlight = true
        defer { refreshInFlight = false }

        // Re-resolved each (non-coalesced) pass so a mid-session change (AI turned
        // off, model downloading) throws and the app re-routes — never a silent
        // no-op. Symmetric with `loadDebtBoard`.
        if case .unavailable(let reason) = await modelAvailabilityResolver() {
            throw StowerMessagesError.languageModelUnavailable(reason)
        }
        // Pre-loop cancellation (before `totalCount` exists) has no meaningful
        // partial summary, so it propagates via `throws`.
        try Task.checkCancellation()

        let reader = try refreshedReader()
        let records = try await reader.conversationStateRecords(windowDays: windowDays, now: now)

        // First-run ABSENCE is created at init (the file is made on open); only a
        // create/open FAILURE — or a `cacheURL: nil` no-cache config — leaves
        // `cache == nil`, in which case no trusted verdict can ever persist. Report
        // all-failed so loading clears and the next pass may rebuild the cache.
        guard let cache, let judge = resolveLanguageModelJudge() else {
            return StowerRefreshSummary(
                changedChatIDs: [],
                judgedCount: 0,
                failedCount: records.count,
                totalCount: records.count
            )
        }
        return await runRefreshPass(records: records, judge: judge, cache: cache)
    }

    internal static func makeSystemLanguageModelJudge() -> StowerReplyExpectationJudge? {
        if #available(macOS 26, iOS 26, *) {
            return StowerFoundationModelReplyJudge()
        }
        return nil
    }

    /// Opens the verdict cache, rebuilding it once if the file is unusable.
    ///
    /// Disposable (M9): a corrupt or unreadable store must be REBUILT, not kept as
    /// a permanently dead cache that silently disables every model verdict for the
    /// provider's lifetime. Drop the file (and its WAL sidecars) and retry once;
    /// return `nil` only if recreation also fails (then refresh reports all-failed
    /// and the next provider may rebuild it).
    ///
    /// The rebuild deletes the file and its WAL/shm sidecars, so it runs only for a
    /// path named like our own cache. A caller-supplied `cacheURL` pointing at
    /// unrelated SQLite data must never be clobbered on open failure.
    internal static func openCache(at url: URL) -> StowerReplyVerdictCaching? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let cache = try? StowerReplyVerdictCache(path: url.path) {
            return cache
        }
        guard url.lastPathComponent == StowerReplyVerdictCache.fileName else {
            return nil
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        return try? StowerReplyVerdictCache(path: url.path)
    }
}
