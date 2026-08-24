# This is a hand-edited (never AI-edited) file of shared terminology of objects and relationships

- **Reader**: It answers questions about messages. `StowerChatDatabaseReader` is the only production reader. `StowerStubFactsReader` is just the test equivalent that has canned messages. 
    - "Reader Protocol" == `StowerConversationFactsReading`. That defines what questions the Reader can answer about iMessages.

- **Bookmark**: is an opaque token meaning "this folder". 
	-  It only needs permission very briefly to read a folder. In Stower, it just copies chat.db in `~/Library/Messages/chat.db` (intended) and `wal` (write-ahead log) and `-shm` (shared memory files) sidecars to a fresh `stower-message-<UUID>` directory in the app's `tmp` folder. It lets go of the permission right after that. 
	- Bookmark comparison just answers the question: "Was this the same folder that this reader was built from?" by comparing bookmark bytes. Not folder paths.

- **Stower Application Process**: it is *one* running instance of the `Stower` executable. It runs everything else. It has its own PID. 

- **applicationWindowScene** -- it is the window scene where the rest of the app runs (including the board)

- **settingsScenes** -- is the one scene (doesn't create window buts something else) that just shows the settings. 

- **Screen**: one mutually exclusive Application Window content state. Changing Screen replaces content inside the existing window; it does not create a Scene, Window, or process.

- Construction — the synchronous action of creating a value and the required dependencies for it to exist.
Composition — the deliberate wiring and instance-sharing relationships among collaborators in an object graph.

- 