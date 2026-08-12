# VANTRA V2 — Phase 13: Secure Offline File Transfer Implementation Plan

## 1. Phase 1-12 Architecture Audit
*   **Protobuf Schema**: Handshake and capabilities negotiation are fully secure. Wire envelopes use `protocol_version = 2` for V2. Text messages, capabilities exchange, media control, and chunks are mapped as plaintext bodies inside the encrypted envelope.
*   **Session Management**: Ephemeral keys are exchanged on every connect, generating directional keys via X25519 ECDH + HKDF-SHA256. Nonces are constructed using 8 bytes of salt + 4 bytes big-endian sequence.
*   **Media Transfer Engine**: Media (image) transfers are structured as `OFFER` -> `ACCEPT` -> `CHUNKS` -> `ACK`. Chunking is currently restricted to the `type: 'IMAGE'` condition in the flusher queue.
*   **Duplicate Detection**: Duplicate messages are rejected on receiver-side by looking up `messageId` before persisting.
*   **Gaps**: The database lacks an integrity hash column (e.g. SHA-256) for verifying files. File messaging needs to be generalized so arbitrary file picking/rendering can reuse the chunking and encryption engine.

---

## 2. Current Phase 12 Media-Transfer Architecture
*   **Sender**: `sendImageMessage` creates a UUID `messageId` and `transferId`, copies the image to `<appDocs>/media/outgoing/`, decodes its dimensions, saves it to SQLite as `IMAGE`, and flushes.
*   **Flusher**: If `msg.type == 'IMAGE'`, the flusher encrypts and transmits an `OFFER` control packet, waits for `ACCEPT`, opens the file, reads 16 KB chunks, encrypts them with directional session keys and unique nonces, and streams them.
*   **Receiver**: Receives `OFFER`, determines `nextExpectedChunk` by scanning existing temp chunk files in `<appDocs>/media/temp/<transferId>/`, saves message metadata as `sending`, and replies with `ACCEPT`. As chunks arrive, they are written to disk. On completion, they are reassembled into `<appDocs>/media/incoming/`, progress is updated to `received`, and a secure ACK is sent.

---

## 3. Generalized File-Transfer Architecture
Rather than duplicating this logic, we will generalize the transfer engine to handle both `IMAGE` and `FILE` types:
*   **Abstract Message Types**: The `Messages` table will support a new type `'FILE'`.
*   **Abstract Transfer Pipeline**: The flusher and chunking loop will evaluate capability checks and directory prefixes dynamically:
    *   `IMAGE` uses prefix `media/` and gate `VantraCapability.image`.
    *   `FILE` uses prefix `files/` and gate `VantraCapability.file`.
*   **Universal Chunking & Encryption**: The exact same chunk encryption, resuming, Accept/Reject control loop, and ACK routines will be reused for both types.

---

## 4. File Message Model
We will update `VantraMessage` domain model with a `sha256` hash field:
```dart
class VantraMessage {
  final String messageId;
  final String senderId;
  final String receiverId;
  final String text; // caption
  final int timestamp;
  final MessageStatus status;
  final int retryCount;
  final String type; // 'TEXT', 'IMAGE', or 'FILE'
  final String? mediaPath; // stores the local file path
  final String? mimeType;
  final String? fileName;
  final int? fileSize;
  final String? transferId;
  final String? sha256; // New complete-file integrity hash
}
```

---

## 5. Protobuf Schema Changes
We will update [vantra_message.proto](file:///c:/Users/Logesh/Documents/Vantra/proto/vantra_message.proto) to add the `sha256` integrity hash inside the `MediaControl` message:
```protobuf
message MediaControl {
  ...
  string sha256 = 12; // Hex-encoded SHA-256 hash of the complete file
}
```
All existing fields remain unmodified, preserving binary compatibility.

---

## 6. Transfer-Control Protocol
We will reuse the `MediaControl` payload types:
*   `OFFER`: Contains metadata, chunk counts, mime-type, and the `sha256` integrity hash.
*   `ACCEPT`: Sent by the receiver to authorize transfer, returning `nextExpectedChunk`.
*   `REJECT`: Sent if capability is missing, file size is too large, or disk space is insufficient.
*   `CANCEL`: Can be sent bidirectionally to immediately abort a transfer and trigger cleanups.

---

## 7. Chunk Protocol
We will reuse the `MediaChunk` message for general file chunks:
```protobuf
message MediaChunk {
  string transfer_id = 1;
  uint32 chunk_index = 2;
  uint32 total_chunks = 3;
  bytes data = 4;
}
```
For file transfers, the `data` bytes will contain the E2E encrypted segments of the arbitrary document file.

---

## 8. Encryption Design
*   We will reuse the session's directional key: `sendKey` for encrypting outgoing chunks, and `receiveKey` for decrypting incoming chunks.
*   Encryption algorithm: ChaCha20-Poly1305.
*   Plaintext payload: The serialized `MediaChunk` bytes.
*   Ciphertext container: `EncryptedEnvelope` wire wrapper.

---

## 9. Nonce Strategy
Nonce reuse is mathematically impossible under this architecture:
1.  **Fresh Keys**: Every reconnection or handshake generates a fresh ephemeral X25519 keypair, deriving brand-new session keys.
2.  **Unique Session Salt**: The salt is constructed dynamically from sorted ephemeral keys, guaranteeing a distinct nonce prefix for each session.
3.  **Monotonic Counter**: Within a session, nonces use the monotonic sequence counter. Retries of a message in a re-established session use fresh keys and reset sequences. Retries in the same session use incremented sequence counters.
4.  **Proof**: Let $S_1$ and $S_2$ be two sessions. If $S_1 \neq S_2$, their keys $K_1 \neq K_2$, preventing key-nonce reuse collisions. If inside the same session $S_1$, the sequence $Seq_i \neq Seq_j$ for any distinct transmissions $i$ and $j$, ensuring nonce uniqueness.

---

## 10. AAD Design
*   For each chunk envelope, the AAD is set to `utf8.encode(messageId)`.
*   This binds the ciphertext to the parent message context.
*   The chunk metadata (`transferId`, `chunkIndex`, `totalChunks`) is serialized inside the plaintext body of the chunk before encryption. Therefore, any tampering with these fields by an attacker will invalidate the Poly1305 MAC tag and result in decryption failure.

---

## 11. File-Integrity/Hash Design
*   **Sender**: Calculates the SHA-256 hash of the source file prior to sending, packing the hex string in the `OFFER`.
*   **Receiver**: 
    1.  Stores the expected `sha256` string in SQLite.
    2.  Once all chunks are reassembled, computes the SHA-256 of the resulting file.
    3.  If `computedHash == expectedHash`, marks status as `received` and ACKs.
    4.  If mismatch occurs, deletes the file, marks status as `failed`, and discards.

---

## 12. Chunking Strategy
*   Default Chunk Size: 16 KB (16,384 bytes). This guarantees low memory consumption and high network reliability over Nearby Connections.
*   Out-of-order chunks are written directly to their corresponding `chunk_<index>` files inside the temporary directory. The receiver reassembles them only when all indexes from `0` to `totalChunks - 1` exist.

---

## 13. Resume Strategy
*   When a connection is lost, the transfer state is preserved in the DB.
*   On auto-reconnection, the sender flushes the queue, sending an `OFFER`.
*   The receiver checks `<appDocs>/files/temp/<transferId>/` and returns the index of the next missing chunk (e.g. `nextExpectedChunk = 450`).
*   The sender resumes transmission starting from chunk 450.

---

## 14. Retry Strategy
*   Chunk-level retries are handled by Google Nearby Connections' reliable socket transport.
*   Session-level interrupts trigger Phase 10 auto-reconnection.
*   Message retry count is tracked in SQLite. If a transfer fails to complete after 5 reconnection/negotiation attempts, it transitions to `failed` to prevent infinite battery drain.

---

## 15. Duplicate Prevention
*   If an `OFFER` is received for a `messageId` that already exists in the database:
    *   If the message status is `received` or `delivered` (completed), the receiver immediately sends a Delivery ACK and discards the offer.
    *   If it is in progress, the receiver continues the resume negotiation.

---

## 16. Delivery-State Model
State transitions for file messages:
*   **Sender**: `pending` (in queue) -> `sending` (negotiating/transferring chunks) -> `delivered` (ACK received).
*   **Receiver**: `sending` (chunks arriving) -> `received` (integrity verified, reassembled, ACK sent).
*   **Failure**: Transition to `failed` on timeout, hash mismatch, or cancellation.

---

## 17. Database/Schema Changes
We will update `Messages` table to add a new `sha256` column:
```dart
class Messages extends Table {
  ...
  TextColumn get sha256 => text().nullable()();
}
```
*   **Migration**: Increment `schemaVersion` to `6` in `app_database.dart` and add:
```dart
if (from < 6) {
  await m.addColumn(messages, messages.sha256);
}
```

---

## 18. Local Storage Architecture
We will organize app-private storage:
*   Outgoing Copy: `<appDocs>/files/outgoing/<messageId>.<ext>`
*   Temporary Chunks: `<appDocs>/files/temp/<transferId>/chunk_<index>`
*   Completed Incoming: `<appDocs>/files/incoming/<messageId>.<ext>`
*   **Cleanup**: Temporary folders are deleted immediately upon reassembly or cancellation.

---

## 19. Android/Kotlin Requirements
*   No new Kotlin changes are required; standard Nearby Connections payloads are handled by the Dart plugin.
*   File transfers are processed as stream bytes over Nearby Connections, preserving full compatibility across versions.

---

## 20. File Picker Strategy
We will integrate the `file_picker` package:
1.  Provides platform-safe file picking via Android Storage Access Framework.
2.  Requires zero broad system storage permissions.
3.  Returns file size, MIME type, name, and access stream.
4.  The app copies the picked file to the private `files/outgoing/` folder immediately to ensure stable chunking access.

---

## 21. Chat UI Changes
We will update [chat_page.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/features/messaging/chat_page.dart):
*   Add an attachment button (`Icons.attach_file_rounded`) for files.
*   Render a specialized file bubble:
    *   Displays file icon (`Icons.insert_drive_file_rounded`), file name, and size.
    *   Shows a linear progress bar and percentage indicator during transfers.
    *   Includes Save / Share / Export actions for completed files.

---

## 22. Capability Integration
*   We will add `VantraCapability.file` to the `supportedCapabilities` list in `CapabilitiesExchange`.
*   File picker is disabled, and file messages cannot be sent if `VantraCapability.file` is not negotiated.

---

## 23. Security Invariants
*   **E2E Encryption**: All chunks are fully encrypted before writing to Nearby Connections sockets.
*   **Session Validity**: Mismatched handshake parameters or blocked contacts will reject connection requests before any control offering begins.
*   **No Internet**: All operations run strictly locally.

---

## 24. Resource-Exhaustion Protections
*   **File Size Cap**: Hard limit of 200 MB per file.
*   **Storage Check**: Receiver checks local storage availability before replying with `ACCEPT`.
*   **Index Guard**: Discards chunks with index values out of bounds (`chunkIndex >= totalChunks`).

---

## 25. Failure/Recovery Matrix
*   **Permission Denied**: Show error banner, set state to `failed`.
*   **Incomplete Chunks on Disconnect**: Keep written chunks, await reconnect to resume.
*   **Hash Mismatch**: Discard reassembled file, update status to `failed`.
*   **App Killed**: Reload database status on restart and queue for reconnection.

---

## 26. Automated Test Plan
Add test suite in `test/messaging_test.dart`:
*   `Test K - File message capability verification`: Asserts file transfers fail if the peer lacks `CAPABILITY_FILE`.
*   `Test L - File chunking, E2E encryption, hash verification, and reassembly`: Simulates a complete file transfer, asserting correct decryption, SHA-256 verification, and reassembly.
*   `Test M - Resumable file transfer after connection interrupt`: Simulates connection failure at 50%, reconnects, verifies resumption from the exact middle chunk, and asserts final file validity.

---

## 27. Physical Two-Device Test Plan
1.  **Small File (PDF/TXT)**: Pick and verify E2E receipt.
2.  **Large File (100 MB APK/ZIP)**: Verify progress smooth rendering and battery stability.
3.  **Offline Queue**: Send file when peer is offline, connect peer, verify auto-negotiation and sending.
4.  **Mid-Transfer Disconnect**: Disable Wi-Fi/Bluetooth at 50%, reconnect, verify resumption.
5.  **App Restart**: Kill sender app during transfer, reopen, assert recovery.

---

## 28. Performance Considerations
*   Chunk size of 16 KB prevents memory spikes by reading stream-wise from the disk instead of loading full files into RAM.
*   Symmetric encryption runs via highly optimized Native bindings from the `cryptography` package.

---

## 29. Migration Requirements
*    Drift schema upgrade from `5` to `6` executes `addColumn` for the `sha256` column, preserving all text and image history.

---

## 30. Risks and Mitigations
*   *Risk*: Inaccessible file picker URIs on Android.
    * *Mitigation*: We copy the selected content stream immediately into the app's cache directory during the selection phase.
*   *Risk*: Memory exhaustion on large files.
    * *Mitigation*: Bounded buffer streams are used during encryption and chunking, releasing blocks immediately after writing.

---

## 31. Final Verification Checklist
*   [ ] Regenerate Protobuf Dart classes.
*   [ ] Increment Drift database schema to version `6` and add migrations.
*   [ ] Generalize messaging provider queue flusher to handle `FILE` message types.
*   [ ] Add `VantraCapability.file` to capabilities exchange.
*   [ ] Integrate `file_picker`, `open_filex`, and `share_plus` contracts.
*   [ ] Add file selection and rendering widgets to `ChatPage`.
*   [ ] Implement automated tests (K, L, M) and confirm all pass.
*   [ ] Build successfully with zero static analysis lints.
*   [ ] Run physical verification scenarios.
