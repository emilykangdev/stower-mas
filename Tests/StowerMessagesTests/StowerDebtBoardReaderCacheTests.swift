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

    @Test("a re-minted bookmark for the same folder still opens a new reader")
    internal func remintedBookmarkForSameFolderReopens() async throws {
        let grant = StowerFakeGrant(bookmark: StowerFakeGrant.first)
        let provider = makeProvider(grant: grant, cache: try StowerReplyVerdictCache.inMemory())

        let before = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)
        #expect(before.map(\.text) == [StowerFakeGrant.firstFolderBody])

        // `onBookmarkRefreshed` persists a re-minted token for the SAME folder:
        // the bytes change, the folder does not.
        grant.regrant(to: StowerFakeGrant.firstReminted)
        let after = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)

        // The comparison is bytewise, not folder-identity, so this re-opens even
        // though nothing moved. That is the deliberate direction: a wasted
        // snapshot copy is cheaper than reusing a reader over a folder the user
        // no longer granted. Comparing resolved folders instead would make this
        // reuse — and would silently pass every other test in this suite.
        #expect(after.map(\.text) == [StowerFakeGrant.firstFolderBody])
        #expect(grant.opens == [StowerFakeGrant.first, StowerFakeGrant.firstReminted])
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

    @Test("a bookmark changed during an open causes another open on the next use")
    internal func changeDuringOpenReopensReader() async throws {
        let grant = StowerFakeGrant(bookmark: StowerFakeGrant.first)
        let provider = StowerDebtBoardProvider(
            readerFactory: { grant.openReader(regrantingTo: StowerFakeGrant.second) },
            readerSourceBookmark: { grant.current },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: try StowerReplyVerdictCache.inMemory()
        )

        let before = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)
        #expect(before.map(\.text) == [StowerFakeGrant.firstFolderBody])

        let after = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)

        #expect(after.map(\.text) == [StowerFakeGrant.secondFolderBody])
        #expect(grant.opens == [StowerFakeGrant.first, StowerFakeGrant.second])
    }

    @Test("a failed replacement open preserves the last good reader and bookmark")
    internal func failedOpenPreservesCache() async throws {
        let grant = StowerFakeGrant(bookmark: StowerFakeGrant.first)
        let provider = StowerDebtBoardProvider(
            readerFactory: { try grant.openReader(failingFor: StowerFakeGrant.second) },
            readerSourceBookmark: { grant.current },
            languageModelJudge: StowerSpyReplyJudge(),
            cache: try StowerReplyVerdictCache.inMemory()
        )

        _ = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)
        grant.regrant(to: StowerFakeGrant.second)

        await #expect(throws: StowerFakeGrantError.openFailed) {
            _ = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)
        }
        await #expect(throws: StowerFakeGrantError.openFailed) {
            _ = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)
        }

        grant.regrant(to: StowerFakeGrant.first)
        let restored = try await provider.recentMessages(chatID: StowerFakeGrant.chatID, limit: 10)

        #expect(restored.map(\.text) == [StowerFakeGrant.firstFolderBody])
        #expect(
            grant.opens == [StowerFakeGrant.first, StowerFakeGrant.second, StowerFakeGrant.second]
        )
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

    /// A re-minted bookmark for the SAME folder as `first`: different bytes,
    /// identical contents.
    ///
    /// Models what `onBookmarkRefreshed` persists after a stale bookmark
    /// resolves — the folder never changed, only the token did. `makeReader`
    /// maps anything that is not `second` to `firstFolderBody`, so a reader
    /// opened from this serves exactly what `first` would.
    fileprivate static let firstReminted = Data("bookmark-folder-one-reminted".utf8)

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
        makeReader(bookmark: recordOpening())
    }

    /// Opens the current source while replacing the grant before the factory returns.
    fileprivate func openReader(regrantingTo newBookmark: Data) -> StowerStubFactsReader {
        let opening = lock.withLock {
            let opening = recordOpeningLocked()
            bookmark = newBookmark
            return opening
        }
        return makeReader(bookmark: opening)
    }

    /// Records an open attempt and fails when the current grant matches `failedBookmark`.
    fileprivate func openReader(failingFor failedBookmark: Data) throws -> StowerStubFactsReader {
        let opening = recordOpening()
        guard opening != failedBookmark else {
            throw StowerFakeGrantError.openFailed
        }
        return makeReader(bookmark: opening)
    }

    private func recordOpening() -> Data {
        lock.withLock { recordOpeningLocked() }
    }

    private func recordOpeningLocked() -> Data {
        opened.append(bookmark)
        return bookmark
    }

    private func makeReader(bookmark: Data) -> StowerStubFactsReader {
        let body = bookmark == Self.second ? Self.secondFolderBody : Self.firstFolderBody
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

private enum StowerFakeGrantError: Error {
    case openFailed
}
