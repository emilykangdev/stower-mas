import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerDebtBoardProvider reader cache")
internal struct StowerDebtBoardReaderCacheTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Re-grant invalidates the cached reader

    @Test("a re-granted bookmark opens a new reader on the very next board load")
    internal func regrantReopensReaderOnLoad() async throws {
        let grant = StowerFakeGrant(bookmark: StowerFakeGrant.first)
        let provider = makeProvider(grant: grant, cache: try StowerReplyVerdictCache.inMemory())

        _ = try await provider.loadDebtBoard(config: config(), now: now)
        #expect(grant.opens == [StowerFakeGrant.first])

        // The user re-grants access via the picker: a different folder's bookmark
        // replaces the stored one while the provider is still alive.
        grant.regrant(to: StowerFakeGrant.second)
        _ = try await provider.loadDebtBoard(config: config(), now: now)

        // Without invalidation the second load reuses the first reader and the
        // board keeps coming from the OLD folder.
        #expect(grant.opens == [StowerFakeGrant.first, StowerFakeGrant.second])
    }

    @Test("a re-granted bookmark serves the new folder's messages on the very next thread tap")
    internal func regrantServesNewFolderOnThreadTap() async throws {
        let grant = StowerFakeGrant(bookmark: StowerFakeGrant.first)
        let provider = makeProvider(grant: grant, cache: try StowerReplyVerdictCache.inMemory())

        let before = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)
        #expect(before.map(\.text) == [StowerFakeGrant.firstFolderBody])

        grant.regrant(to: StowerFakeGrant.second)
        let after = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)

        #expect(after.map(\.text) == [StowerFakeGrant.secondFolderBody])
    }

    // MARK: - Reuse still holds while the grant is unchanged

    @Test("an unchanged bookmark reuses one reader across repeated loads and thread taps")
    internal func unchangedBookmarkReusesReader() async throws {
        let grant = StowerFakeGrant(bookmark: StowerFakeGrant.first)
        let provider = makeProvider(grant: grant, cache: try StowerReplyVerdictCache.inMemory())

        // Opening a reader copies chat.db and runs an integrity check, so the
        // invalidation must not degrade into opening one per call.
        _ = try await provider.loadDebtBoard(config: config(), now: now)
        _ = try await provider.loadDebtBoard(config: config(), now: now)
        _ = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)

        #expect(grant.opens == [StowerFakeGrant.first])
    }

    @Test("a load after a refresh reuses the reader the refresh opened")
    internal func loadAfterRefreshReusesRefreshedReader() async throws {
        let grant = StowerFakeGrant(bookmark: StowerFakeGrant.first)
        let provider = makeProvider(grant: grant, cache: try StowerReplyVerdictCache.inMemory())

        // `refreshJudgments` always rebuilds the reader; it must record the
        // bookmark it opened from, or the stale recording mismatches on every
        // later call and re-opens a reader per load and per thread tap.
        _ = try await provider.refreshJudgments(config: config(), now: now)
        _ = try await provider.loadDebtBoard(config: config(), now: now)
        _ = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)

        #expect(grant.opens == [StowerFakeGrant.first])
    }

    @Test("a provider with no bookmark-backed source reuses one reader across loads")
    internal func bookmarklessSourceReusesReader() async throws {
        // The DEBUG demo initializer and the test doubles pass no bookmark, so
        // `readerSourceBookmark` defaults to nil here; a nil source must read as
        // "cannot change", never as "always changed".
        let grant = StowerFakeGrant(bookmark: StowerFakeGrant.first)
        let provider = StowerDebtBoardProvider(
            readerFactory: { grant.openReader() },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: try StowerReplyVerdictCache.inMemory()
        )

        _ = try await provider.loadDebtBoard(config: config(), now: now)
        _ = try await provider.loadDebtBoard(config: config(), now: now)

        #expect(grant.opens.count == 1)
    }

    // MARK: - Helpers

    private func makeProvider(
        grant: StowerFakeGrant,
        cache: StowerReplyVerdictCaching
    ) -> StowerDebtBoardProvider {
        StowerDebtBoardProvider(
            readerFactory: { grant.openReader() },
            readerSourceBookmark: { grant.current },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: cache
        )
    }

    private func config(unansweredForDays: Int = 7) -> StowerDebtConfig {
        StowerDebtConfig(unansweredForDays: unansweredForDays)
    }
}

/// A stand-in for the stored Messages-access bookmark plus the folder behind it.
///
/// Mirrors production's shape: `openReader()` re-reads the current bookmark the way
/// `StowerChatDatabaseReader`'s production initializer does, and records every open
/// so a test can tell reuse from a re-open. Each bookmark maps to a different
/// folder's contents, so a reader built from the wrong one is observable.
private final class StowerFakeGrant: @unchecked Sendable {
    /// The bookmark the user granted first.
    fileprivate static let first = Data("bookmark-folder-one".utf8)

    /// The bookmark a later re-grant stores over it.
    fileprivate static let second = Data("bookmark-folder-two".utf8)

    /// The one conversation both folders happen to carry, with different bodies.
    fileprivate static let chatID = "chat-1"

    fileprivate static let firstFolderBody = "message from the first folder"
    fileprivate static let secondFolderBody = "message from the second folder"

    /// The fixed instant every stubbed thread message carries; the reader-cache
    /// behaviour under test is independent of it.
    fileprivate static let messageTimestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let lock = NSLock()
    private var bookmark: Data
    private var opened: [Data] = []

    fileprivate init(bookmark: Data) {
        self.bookmark = bookmark
    }

    /// The currently stored bookmark, as `loadMessagesAccessBookmark` would read it.
    fileprivate var current: Data? {
        lock.withLock { bookmark }
    }

    /// The bookmark each reader open read, oldest first.
    fileprivate var opens: [Data] {
        lock.withLock { opened }
    }

    /// Replaces the stored bookmark, as the picker's grant path does.
    fileprivate func regrant(to newBookmark: Data) {
        lock.withLock { bookmark = newBookmark }
    }

    /// Opens a reader over whichever folder is granted right now.
    fileprivate func openReader() -> StowerStubFactsReader {
        let opening = lock.withLock {
            opened.append(bookmark)
            return bookmark
        }
        let body = opening == Self.second ? Self.secondFolderBody : Self.firstFolderBody
        var reader = StowerStubFactsReader(records: [])
        reader.threads = [
            Self.chatID: [
                StowerThreadMessage(
                    id: "\(Self.chatID)-guid",
                    isFromMe: false,
                    timestamp: Self.messageTimestamp,
                    text: body,
                    kind: .text
                )
            ]
        ]
        return reader
    }
}
