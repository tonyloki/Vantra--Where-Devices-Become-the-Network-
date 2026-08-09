# VANTRA — Phase 5: Protocol & Serialization Layer Walkthrough

## Summary of Accomplishments

Phase 5 replaced JSON transport-wire payloads with **Protocol Buffers (Protobuf)** without plaintext fallback, while preserving all Phase 1–4 cryptographic invariants, SQLite message history, and reactive Chat UI state.

---

## 1. Protobuf Schema & Dart Code Generation

- **Proto Schema**: [`proto/vantra_message.proto`](file:///c:/Users/Logesh/Documents/Vantra/proto/vantra_message.proto)
  - `VantraWireEnvelope`: Wire-level discriminator envelope holding `oneof payload` (`IdentitySecurePayload`, `EncryptedEnvelope`, `ProtocolErrorPayload`).
  - `IdentitySecurePayload`: Protocol version, peer ID, display name, 32-byte Ed25519 identity key, 32-byte X25519 ephemeral key, 64-byte Ed25519 canonical signature.
  - `EncryptedEnvelope`: Protocol version, outer packet message ID, session ID, sequence counter, 12-byte nonce, ciphertext bytes, 16-byte MAC.
  - `VantraPlaintext`: Authenticated inner decrypted payload with `oneof body` (`TextBody`, `AckBody`).
  - `DeliveryStatus`: Domain delivery enum (`DELIVERY_DELIVERED`, `DELIVERY_UNSPECIFIED`).
  - `ProtocolErrorPayload`: Outer error signal for pre-handshake protocol issues (untrusted, unauthenticated).
- **Generated Code**: Built into `lib/generated/vantra_message.pb*.dart`.

---

## 2. Protocol Abstraction Layer (`lib/core/protocol/`)

- [`protocol_version.dart`](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_version.dart): Defined `kCurrentProtocolVersion = 1` and `kMinSupportedProtocolVersion = 1`.
- [`protocol_exception.dart`](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_exception.dart): Defined typed `ProtocolValidationException`.
- [`protocol_message.dart`](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_message.dart): Clean domain models decouples domain logic from Protobuf serialization classes.
- [`protocol_codec.dart`](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_codec.dart): Interface defining wire envelope and plaintext payload codecs.
- [`protobuf_codec.dart`](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protobuf_codec.dart): Strict validator & serializer:
  - Validates protocol versions (`v == 1`).
  - Enforces exact cryptographic byte lengths (32-byte keys, 64-byte signatures, 12-byte nonces, 16-byte MACs).
  - Enforces positive monotonic sequence numbers (`sequence > 0`).

---

## 3. Cryptographic Invariants & Encrypted ACKs

- **Direct Binary AEAD Cryptography**: [`CryptoService.encryptBytes`](file:///c:/Users/Logesh/Documents/Vantra/lib/core/security/crypto_service.dart) and [`CryptoService.decryptBytes`](file:///c:/Users/Logesh/Documents/Vantra/lib/core/security/crypto_service.dart) operate directly on binary byte buffers.
- **ACK Security Invariant**: Application ACKs are strictly inside encrypted `VantraPlaintext.ackBody`. No unauthenticated plaintext ACKs exist.
- **ACK ID Disjointness Invariant**:
  - Outer `EncryptedEnvelope.message_id = ackPacketId` (unique UUID).
  - Inner `VantraPlaintext.message_id = ackPacketId`.
  - `AckBody.original_message_id = originalMessageId`.
  - Invariant: `ackPacketId != originalMessageId`.
  - AAD is strictly `utf8.encode(ackPacketId)`.
  - Receiver increments its own monotonic sending sequence to encrypt the ACK; Sender decrypts and verifies sequence replay protection before updating local message status in SQLite to `MessageStatus.delivered`.

---

## 4. UI & Status Updates

- [`MessageStatus`](file:///c:/Users/Logesh/Documents/Vantra/lib/core/models/message_status.dart): Added `delivered` status.
- [`ChatPage`](file:///c:/Users/Logesh/Documents/Vantra/lib/features/messaging/chat_page.dart): Rendered double checkmark `Icons.done_all` in cyan for delivered messages.

---

## 5. Verification & Test Results

### 1. `flutter analyze`
```
Analyzing Vantra...
No issues found! (ran in 8.1s)
```

### 2. `flutter test` (42 Tests Passing)
- `test/protocol_protobuf_test.dart`: Protobuf round-trip, malformed bytes rejection, length validations.
- `test/crypto_protobuf_test.dart`: Encrypted Protobuf round-trip, ACK invariant validation, ID disjointness.
- `test/security_persistence_test.dart`: End-to-end encrypted messaging, replay protection, encrypted delivery ACK flow.
- `test/handshake_test.dart`: Handshake protocol with Protobuf wire format and signature verification.
- `test/messaging_test.dart`: Messaging provider with Protobuf wire format and peer session management.
- `test/messaging_persistence_test.dart`: Database persistence & failure status tracking.
- `test/chat_widget_test.dart` & `test/chat_persistence_widget_test.dart`: Chat UI and reactive stream persistence.
- `test/crypto_test.dart`, `test/transport_test.dart`, `test/poc_page_test.dart`, `test/widget_test.dart`.

```
00:12 +42: All tests passed!
```

### 3. `flutter build apk --debug`
```
√ Built build\app\outputs\flutter-apk\app-debug.apk
```
