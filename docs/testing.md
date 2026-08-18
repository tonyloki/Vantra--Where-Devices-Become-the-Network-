# VANTRA — Testing Guidelines

## Phase Status

*   **Current Phase:** Phase 18: Large Media Streaming (Direct to Disk)
*   **Status:** Direct-to-disk random-access media streaming verified via 167 automated unit, integration, and widget tests.

---

## Automated Verification Suite

Vantra includes **167 automated unit, widget, and integration tests** to guarantee cryptographic security, protocol accuracy, and UI correctness:
- **`test/crypto_test.dart`**: Verifies X25519 DH key agreements, Ed25519 identity verification, ChaCha20-Poly1305 AEAD ciphers, 64-packet sliding window replay protection, and transcript length verification.
- **`test/database_test.dart` & `test/repository_test.dart`**: Verifies Drift persistence layer, bilaterally ordered message chats, message queues, read states, atomic retry increments, startup recovery (retaining delivered state), and duplicate message prevention.
- **`test/conversations_test.dart`**: Verifies optimized conversation summaries reactively using raw SQL queries and stream combineLatest3 mapping.
- **`test/peer_discovery_test.dart`**: Verifies colon-delimited displayName and peerId advertising name parsing.
- **`test/trust_block_test.dart`**: Verifies security blocking invariants, distrusted peer connection rejections, and signature checking.
- **`test/mesh_reliability_test.dart`**: Verifies dynamic link-failure detection, Route Error (RERR) propagation, path rediscovery, next-hop invalidation, and hop-level retries.
- **`test/media_streaming_test.dart`**: Verifies Phase 18 direct-to-disk random-access streaming, including out-of-order chunk writing, duplicate packet rejection, boundary and overflow checks, SHA-256 checksum validation, atomic move/rename, file descriptor closing, 30-second inactivity watchdog cleanup, and simultaneous isolated transfers.
- **`test/widget_test.dart` & `test/chat_widget_test.dart`**: Verifies animated splash loaders, conversations empty states, chat bubbles, unread counts, text composers, and location warnings.

---

## Manual Physical Device Validation Guidelines

To manually verify secure text and media transfers offline on physical Android devices:

### 1. Connection Establishment
1. Ensure both Device A and Device B have Cellular data turned OFF and Wi-Fi Internet disconnected.
2. Launch Vantra on both devices. Confirm the entry splash animation boots successfully.
3. Confirm Nearby discovery starts automatically.
4. On Device A, open the "Nearby" tab and connect to Device B.
5. Accept the connection pairing code prompt on both devices.
6. Verify connection status transitions to "Connected" on both devices.

### 2. Bidirectional Text Messaging
1. Open the chat session between Device A and Device B.
2. Verify that the UI reports "Securely Connected".
3. Send text messages bidirectionally. Verify that checkmarks update to indicate successful delivery.

### 3. Secure File and Image Transfer
1. On Device A, click the attachment button (+), select an image, and click send.
2. Verify that:
   * Device A displays the image preview bubble with a progress indicator showing chunk upload progress.
   * Device B shows progress updating as chunk packets are received.
   * Once reassembly completes, Device B computes and verifies the SHA-256 hash successfully, rendering the final image.
   * Device A's bubble status transitions to `sent` when the receiver sends the final delivery ACK.
3. Repeat the steps in the other direction (Device B → Device A) to verify bidirectional media transfers.
4. Attempt to send an arbitrary file (e.g. PDF/TXT) and verify that it transfers successfully and is saved under the `<appDocs>/files/incoming/` directory.
