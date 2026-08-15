# This is a hand-edited (never AI-edited) file of shared terminology of objects and relationships

- **Reader**: It answers questions about messages. `StowerChatDatabaseReader` is the only production reader. `StowerStubFactsReader` is just the test equivalent that has canned messages. 
    - "Reader Protocol" == `StowerConversationFactsReading`. That defines what questions the Reader can answer about iMessages.

- **Bookmark**: is an opaque token meaning "this folder". 
	-  It only needs permission very briefly to read a folder. In Stower, it just copies chat.db in `~/Library/Messages/chat.db` (intended) and `wal` (write-ahead log) and `-shm` (shared memory files) sidecars to a fresh `stower-message-<UUID>` directory in the app's `tmp` folder. It lets go of the permission right after that. 
	- Bookmark comparison just answers the question: "Was this the same folder that this reader was built from?" by comparing bookmark bytes. Not folder paths.

