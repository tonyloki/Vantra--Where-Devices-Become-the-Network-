# VANTRA — Testing Guidelines

## Phase Status

*   **Current Phase:** Phase 9
*   **Status:** Automated unit tests, widget tests, and physical-device connection validation guidelines completed.

## Automated Verification Suite
Vantra includes 56 automated unit and widget tests:
- **`test/crypto_test.dart`**: Verifies X25519 DH key agreements, Ed25519 identity verification, and ChaCha20-Poly1305 AEAD integrity.
- **`test/db_test.dart` & `test/repository_test.dart`**: Verifies Drift persistence layer, message queues, read states, and duplicate message prevention.
- **`test/trust_block_test.dart`**: Verifies security blocking invariants, distrusted peer connection rejections, and signature checking.
- **`test/widget_test.dart` & `test/chat_widget_test.dart`**: Verifies animated splash loaders, conversations empty states, chat bubbles, unread counts, text composers, and location warnings.

## Manual Physical Device Validation Guidelines
1. Ensure both devices have Cellular data turned OFF and Wi-Fi Internet disconnected.
2. Launch Vantra on both devices. Confirm the entry animation plays and boots successfully.
3. Confirm Nearby discovery starts automatically.
4. On Device A, open "Nearby" tab and connect to Device B.
5. Accept the connection pairing code prompt.
6. Verify connection status transitions to "Connected" on both devices.
7. Open Chat, type message and verify delivered checkmarks, and background/resume battery-saver behaviors.
