# VANTRA — Phase 5: Protocol & Serialization Layer Implementation Plan (Audited & Approved)

## Goal
Migrate the VANTRA wire protocol from temporary JSON encoding to **Protocol Buffers (Protobuf)**, establishing a strict, versioned, binary protocol with end-to-end encrypted delivery acknowledgments (ACKs) and rigorous malformed-packet protection, while strictly preserving all Phase 1–4 capabilities (P2P Nearby transport, Ed25519 identity authentication, X25519 ECDH key agreement, ChaCha20-Poly1305 AEAD, replay protection, SQLite persistence, and Chat UI).

---

## Strict Cryptographic & Protocol Invariants

### 1. Unique Message ID Invariant for ACKs
- **Every encrypted wire packet has its own unique `messageId`**:
  - `EncryptedEnvelope.message_id` = unique ACK packet ID (`ackPacketId`)
  - `VantraPlaintext.message_id` = same unique ACK packet ID (`ackPacketId`)
  - `AckBody.original_message_id` = `originalMessageId` (the ID of the text message being acknowledged)
- **Invariant**: `ackPacketId != originalMessageId`.
- **AAD Construction**: Associated Data (AAD) for the ACK packet is `utf8.encode(ackPacketId)`.
- **Replay Protection**: The receiver processes the ACK packet under the ACK packet's own monotonic sequence number and session ID.
- **Delivery State Update**: `original_message_id` is used solely to locate and transition the existing message record in SQLite to `MessageStatus.delivered`.

### 2. End-to-End Encrypted ACK Security
- **No Unauthenticated Outer ACKs**: Application-level delivery ACKs are **never** transmitted in plaintext on the outer wire.
- **Unified Encrypted Plaintext (`VantraPlaintext`)**: Both text messages (`TextBody`) and acknowledgments (`AckBody`) are represented inside `VantraPlaintext` and encrypted using ChaCha20-Poly1305 AEAD under the active directional session keys.
- **Delivery Semantics**: `DeliveryStatus.DELIVERY_DELIVERED` confirms the receiving device successfully authenticated, decrypted, validated, and persisted the message into SQLite.

### 3. Protocol Error Boundary
- `ProtocolErrorPayload` is restricted to pre-session protocol-level errors (e.g. unsupported version, outer malformed envelope).
- **Security Constraint**: An unauthenticated outer protocol error packet **must never** alter session security state, change trust states, or mark messages as delivered.

### 4. Preserved Canonical Handshake Signing
- Handshake signatures **continue to use the existing `CanonicalEncoder`** (`VANTRA_HANDSHAKE_DOMAIN` + version + length-prefixed fields).
- Protobuf is used solely for wire packaging (`IdentitySecurePayload`), ensuring deterministic signature generation and preventing serialization drift.

### 5. Preserved Cryptographic Invariants
- **Identity & Handshake**: Ed25519 signing/verification, X25519 ECDH key exchange.
- **Key Derivation**: HKDF-SHA256 with symmetric directional assignment determined by lexicographical public key comparison (`_compareBytes`).
- **AEAD Encryption**: ChaCha20-Poly1305 with 12-byte counter nonce (`sessionSalt[0..8] + sequence[0..4]`) and Associated Data (AAD) = UTF-8 encoded packet `messageId`.
- **Replay Protection**: In-memory monotonic sequence counters (`sendSequence`, `receiveSequence`) and session ID binding.

### 6. Wire Format & Versioning
- **Protobuf-Only Wire**: Zero JSON serialization across the P2P transport.
- **Version Constants**: `kCurrentProtocolVersion = 1`, `kMinSupportedProtocolVersion = 1`. Unsupported versions are safely rejected.

---

## Detailed Component & File-by-File Changes

### 1. Protobuf Schema & Code Generation
#### [MODIFY] [vantra_message.proto](file:///c:/Users/Logesh/Documents/Vantra/proto/vantra_message.proto)
Define the canonical version 1 protobuf schema:
- `VantraWireEnvelope`: Outer packet with `protocol_version` and `oneof payload` (`IdentitySecurePayload handshake`, `EncryptedEnvelope encrypted_message`, `ProtocolErrorPayload error`).
- `IdentitySecurePayload`: `peer_id`, `display_name`, `identity_public_key` (bytes), `ephemeral_public_key` (bytes), `signature` (bytes).
- `EncryptedEnvelope`: `message_id`, `session_id`, `sequence`, `nonce` (bytes), `ciphertext` (bytes), `mac` (bytes).
- `VantraPlaintext`: Inner payload with `message_id`, `session_id`, `sequence`, `timestamp_ms`, `sender_id`, `receiver_id`, and `oneof body` (`TextBody text`, `AckBody ack`).
- `TextBody`: `string content = 1;`
- `AckBody`: `string original_message_id = 1; DeliveryStatus status = 2;`
- `DeliveryStatus`: `DELIVERY_UNSPECIFIED = 0; DELIVERY_DELIVERED = 1;`
- `ProtocolErrorPayload`: `uint32 error_code = 1; string error_message = 2; string related_message_id = 3;`

#### [NEW] Generated Dart Protobuf Files (`lib/generated/`)
- `lib/generated/vantra_message.pb.dart`
- `lib/generated/vantra_message.pbenum.dart`
- `lib/generated/vantra_message.pbjson.dart`

---

### 2. Protocol Abstraction Layer (`lib/core/protocol/`)
#### [NEW] [protocol_version.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_version.dart)
Defines protocol version constants (`kCurrentProtocolVersion = 1`, `kMinSupportedProtocolVersion = 1`).

#### [NEW] [protocol_exception.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_exception.dart)
Defines `ProtocolValidationException` for safe packet rejection and error codes without throwing unhandled exceptions.

#### [NEW] [protocol_message.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_message.dart)
Domain-level data models isolating application logic from direct protobuf class coupling:
- `DomainWireEnvelope`
- `DomainHandshakePayload`
- `DomainEncryptedEnvelope`
- `DomainPlaintext` (`DomainTextMessage`, `DomainAckMessage`)
- `DomainProtocolError`

#### [NEW] [protocol_codec.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_codec.dart)
Abstract interface defining encoding and decoding methods for wire envelopes and plaintext payloads.

#### [NEW] [protobuf_codec.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protobuf_codec.dart)
Implements `ProtocolCodec` with strict validation:
- Enforces `protocol_version == 1`.
- Enforces exact field lengths: Ed25519/X25519 keys = 32 bytes, Ed25519 signature = 64 bytes, nonce = 12 bytes, MAC = 16 bytes.
- Enforces non-empty IDs (`messageId`, `peerId`, `sessionId`) and non-empty ciphertext.
- Safely catches and wraps protobuf parsing errors into `ProtocolValidationException`.

---

### 3. Cryptography & Security Layer (`lib/core/security/`)
#### [MODIFY] [crypto_service.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/security/crypto_service.dart)
- Add binary payload encryption/decryption: `encryptBytes()` and `decryptBytes()` operating directly on `Uint8List` bytes (the encoded `VantraPlaintext` protobuf) while keeping ChaCha20-Poly1305 and AAD (`utf8.encode(messageId)`).

---

### 4. Messaging & Persistence Layer (`lib/core/messaging/`)
#### [MODIFY] [messaging_service.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/messaging/messaging_service.dart)
- Integrate `ProtocolCodec` for incoming and outgoing wire bytes.
- Remove all JSON string parsing; dispatch strongly-typed domain events.

#### [MODIFY] [messaging_provider.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/messaging/messaging_provider.dart)
- **Outbound Text**: Encodes `VantraPlaintext(TextBody)` $\rightarrow$ encrypts $\rightarrow$ wraps in `VantraWireEnvelope(EncryptedEnvelope)` $\rightarrow$ `Transport.send()`.
- **Inbound Encrypted Payload**:
  1. Decrypts `EncryptedEnvelope` using `session.receiveKey`.
  2. Decodes `VantraPlaintext` via `ProtocolCodec`.
  3. Validates sequence monotonic counter and session ID.
  4. If `TextBody`: saves to SQLite with `MessageStatus.received` $\rightarrow$ builds and sends encrypted `AckBody(original_message_id: originalId, status: DELIVERY_DELIVERED)` with its own unique `ackPacketId` back to sender.
  5. If `AckBody`: verifies `originalMessageId` and updates local message status in SQLite to `MessageStatus.delivered`.

#### [MODIFY] [messaging_repository.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/messaging/messaging_repository.dart)
- Support `updateMessageStatus(messageId, MessageStatus.delivered)`.

---

## Verification Plan

### Automated Test Suites (`test/`)
1. **`test/protocol_protobuf_test.dart`** [NEW]:
   - Protobuf serialization/deserialization round-trip for all envelope and body types.
   - Strict field length enforcement (32-byte keys, 64-byte signatures, 12-byte nonces, 16-byte MACs).
   - Version rejection tests (`v0`, `v999`).
   - Truncated/corrupted byte rejection without crash.
   - Missing required fields validation.
2. **`test/crypto_protobuf_test.dart`** [NEW]:
   - `VantraPlaintext` protobuf $\rightarrow$ ChaCha20-Poly1305 AEAD $\rightarrow$ `EncryptedEnvelope` protobuf $\rightarrow$ decrypt $\rightarrow$ verify exact message content.
3. **`test/security_persistence_test.dart`** [MODIFY]:
   - Complete end-to-end bidirectional text delivery with encrypted ACK round-trip:
     - Device A sends text $\rightarrow$ Device B decrypts and persists as `received` $\rightarrow$ Device B sends encrypted ACK with distinct `ackPacketId` $\rightarrow$ Device A decrypts ACK and updates status to `delivered`.
   - **ACK ID Disjointness Test**: Unit test verifying `ackPacketId != originalMessageId` and AAD matches `ackPacketId`.
   - Forged unauthenticated plaintext ACK rejection test (verifying that only authenticated encrypted ACKs update status).
   - Sequence replay protection on protobuf wire packets.
4. **Existing Test Suite Compatibility**:
   - Update `handshake_test.dart`, `messaging_test.dart`, `chat_widget_test.dart` to use `ProtocolCodec`.
   - Run `flutter analyze` $\rightarrow$ 0 issues.
   - Run `flutter test` $\rightarrow$ 100% tests passing.
   - Run `flutter build apk --debug` $\rightarrow$ successful APK generation.
