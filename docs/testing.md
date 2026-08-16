# VANTRA — Testing Guidelines

## Phase Status

*   **Current Phase:** Production Hardening
*   **Status:** Comprehensive automated testing suite (154 tests) and manual multi-device image/file verification guidelines completed.

---

## Automated Verification Suite

Vantra includes **154 automated unit, widget, and integration tests** to guarantee cryptographic security, protocol accuracy, and UI correctness:
- **`test/crypto_test.dart`**: Verifies X25519 DH key agreements, Ed25519 identity verification, ChaCha20-Poly1305 AEAD ciphers, 64-packet sliding window replay protection, and transcript length verification.
- **`test/database_test.dart` & `test/repository_test.dart`**: Verifies Drift persistence layer, bilaterally ordered message chats, message queues, read states, atomic retry increments, startup recovery (retaining delivered state), and duplicate message prevention.
- **`test/conversations_test.dart`**: Verifies optimized conversation summaries reactively using raw SQL queries and stream combineLatest3 mapping.
- **`test/peer_discovery_test.dart`**: Verifies colon-delimited displayName and peerId advertising name parsing.
- **`test/trust_block_test.dart`**: Verifies security blocking invariants, distrusted peer connection rejections, and signature checking.
- **`test/multi_peer_test.dart` & `test/messaging_test.dart`**: Complete multi-peer routing and media integration tests covering:
  - V2 version negotiation and compatibility fallbacks.
  - Asynchronous capability exchanges and connection recovery checks.
  - Image chunking, E2E encrypted transmission, and receiver reassembly.
  - Resumable chunk transfer negotiation (ACCEPT chunk resumption indexes).
  - SHA-256 integrity hash verification, 500 MB size limit checks, and failure drop routines.
  - Temporary directory chunk file cleanups on all reject/timeout/disconnect paths, and multi-peer directory isolation.
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

