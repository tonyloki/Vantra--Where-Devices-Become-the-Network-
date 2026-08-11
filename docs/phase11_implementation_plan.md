# VANTRA V2 — Phase 11: Protocol V2 & Capability Negotiation Implementation Plan

This implementation plan details the architecture, design patterns, and file changes required to evolve VANTRA's wire protocol into a capability-aware, forward-compatible system (Protocol V2).

---

## 1. Phase 1–10 Protocol Architecture Audit

*   **P2P Transport**: Native Google Nearby Connections via `Transport` / `NearbyTransport`.
*   **Serialized Wire Envelope**: `VantraWireEnvelope` (version `1`).
*   **Decrypted Plaintext**: `VantraPlaintext` containing `oneof body` with `TextBody` and `AckBody`.
*   **Security Boundary**: Ephemeral X25519 Diffie-Hellman key agreement, Ed25519 signature validation during handshake, HKDF session key derivation, and ChaCha20-Poly1305 symmetric message encryption.
*   **Queueing**: Outgoing messages are stored in SQLite and flushed sequentially in FIFO order once a secure session is established.
*   **Reconnection**: Phase 10 background auto-connection triggers for trusted peers, deriving a fresh secure session.

---

## 2. Current Protocol V1 Limitations

*   **Static Message Payload**: `VantraPlaintext` only supports `TextBody` and `AckBody`. Adding new types (images, files) requires altering the core message structure, which is not forward-compatible.
*   **No Capability Awareness**: Devices assume their peer supports all features. There is no mechanism to announce supported features or negotiate them before communication begins.
*   **Static Versioning**: No range negotiation; version mismatch results in immediate disconnect.

---

## 3. Proposed V2 Versioning Architecture

To support future features while remaining backward-compatible, VANTRA will split protocol control into two layers:
1.  **Wire Protocol Version**: Determines the structural decoding rules for the envelope (e.g. `V1`, `V2`).
2.  **Feature Capabilities**: Declares specific features supported by the application binary (e.g. `TEXT`, `IMAGE`, `FILE`).

---

## 4. Capability Registry Design

We define a protobuf enum representing supported capabilities:

```protobuf
enum Capability {
  CAPABILITY_UNSPECIFIED = 0;
  CAPABILITY_TEXT = 1;
  CAPABILITY_IMAGE = 2;
  CAPABILITY_AUDIO = 3;
  CAPABILITY_VIDEO = 4;
  CAPABILITY_FILE = 5;
  CAPABILITY_GROUP = 6;
}
```

For Phase 11, the application will only advertise and enable `CAPABILITY_TEXT`. Future capabilities are registered in the schema but remain unadvertised.

---

## 5. Version and Capability Negotiation Design

Capabilities and version ranges are negotiated inside the **authenticated encrypted channel** immediately after the connection becomes `CONNECTED` and before any queue flushing or user messaging begins:

```text
Nearby connection
      ↓
IDENTITY_SECURE (V1-compatible handshake)
      ↓
Ed25519 signature verified
      ↓
Symmetric Session Keys Derived (X25519 + HKDF)
      ↓
Session Status: handshaking (authenticating)
      ↓
First encrypted packet: VantraPlaintext(CapabilitiesExchange)
      ↓
Verify peer's capabilities & version ranges
      ↓
Negotiated version & capability intersection computed
      ↓
Session Status: connected (secure & ready)
      ↓
FIFO Queue Flush (Text Messages)
```

### Legacy V1 Device Fallback
If a V2 device receives a handshake with `protocol_version = 1`, it:
1.  Bypasses the `CapabilitiesExchange` step.
2.  Immediately transitions the session to `SessionStatus.connected`.
3.  Defaults the negotiated capabilities to `[CAPABILITY_TEXT]`.

---

## 6. Secure Negotiation Boundary & Downgrade Protection

*   **Boundary**: Capability negotiation happens exclusively within the encrypted session tunnel (`VantraPlaintext` encrypted via ChaCha20-Poly1305). No capability claims are exposed or processed outside the authenticated encryption boundary.
*   **Downgrade Protection**: If a V2 device connects to a V2 peer, it enforces the capability exchange. If the peer attempts to send messages before completing the capability exchange or attempts to downgrade the session without authorization, the connection is immediately terminated.

---

## 7. Protocol Message Design

We expand `vantra_message.proto` to include a new body type `CapabilitiesExchange`:

```protobuf
syntax = "proto3";

package vantra.protocol;

option java_package = "me.vantra.proto";
option java_outer_classname = "VantraProto";

// Outer wire envelope remains backward-compatible
message VantraWireEnvelope {
  uint32 protocol_version = 1;

  oneof payload {
    IdentitySecurePayload handshake = 2;
    EncryptedEnvelope encrypted_message = 3;
    ProtocolErrorPayload error = 4;
  }
}

message IdentitySecurePayload {
  string peer_id = 1;
  string display_name = 2;
  bytes identity_public_key = 3;
  bytes ephemeral_public_key = 4;
  bytes signature = 5;
}

message EncryptedEnvelope {
  string message_id = 1;
  string session_id = 2;
  uint64 sequence = 3;
  bytes nonce = 4;
  bytes ciphertext = 5;
  bytes mac = 6;
}

message VantraPlaintext {
  string message_id = 1;
  string session_id = 2;
  uint64 sequence = 3;
  int64 timestamp_ms = 4;
  string sender_id = 5;
  string receiver_id = 6;

  oneof body {
    TextBody text = 7;
    AckBody ack = 8;
    CapabilitiesExchange capabilities_exchange = 9; // New in V2
  }
}

message TextBody {
  string content = 1;
}

message AckBody {
  string original_message_id = 1;
  DeliveryStatus status = 2;
}

message CapabilitiesExchange {
  uint32 min_supported_version = 1;
  uint32 max_supported_version = 2;
  repeated Capability supported_capabilities = 3;
}

enum Capability {
  CAPABILITY_UNSPECIFIED = 0;
  CAPABILITY_TEXT = 1;
  CAPABILITY_IMAGE = 2;
  CAPABILITY_AUDIO = 3;
  CAPABILITY_VIDEO = 4;
  CAPABILITY_FILE = 5;
  CAPABILITY_GROUP = 6;
}

enum DeliveryStatus {
  DELIVERY_UNSPECIFIED = 0;
  DELIVERY_DELIVERED = 1;
}

message ProtocolErrorPayload {
  uint32 error_code = 1;
  string error_message = 2;
  string related_message_id = 3;
}
```

---

## 8. Unknown Fields and Fail-Safe Handling

*   **Protobuf Tolerance**: Unknown fields are ignored during parsing without crashing.
*   **Unknown Capabilities**: Unsupported enums or message variants are parsed as `CAPABILITY_UNSPECIFIED` and ignored.
*   **Fail-Safe**: If an unsupported capability is requested or encountered, it triggers a warning message in the UI: `"This device does not support this content type."`

---

## 9. File-by-File Changes

### [vantra_message.proto](file:///c:/Users/Logesh/Documents/Vantra/proto/vantra_message.proto)
*   Add the `CapabilitiesExchange` message.
*   Add the `Capability` enum.
*   Incorporate `CapabilitiesExchange` inside `VantraPlaintext` under field index `9`.

### [protocol_version.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_version.dart)
*   Increment `kCurrentProtocolVersion` to `2`.
*   Maintain `kMinSupportedProtocolVersion` at `1` to preserve backward compatibility.

### [protocol_message.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_message.dart)
*   Define the `DomainCapabilitiesExchange` class extending `DomainPlaintext`.
*   Expose the `VantraCapability` enum in Dart.

### [protobuf_codec.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protobuf_codec.dart)
*   Add serialization and deserialization mapping for `DomainCapabilitiesExchange`.

### [messaging_provider.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/messaging/messaging_provider.dart)
*   **State Updates**: Expose negotiated capabilities list in `PeerSession`.
*   **Auto-Accept & Handshake**:
    *   During handshake, check `protocolVersion` of incoming `SessionSecureIdentity`.
    *   If version = 1: Transition session immediately to `SessionStatus.connected`, negotiated version = 1, and enabled capabilities = `[text]`.
    *   If version = 2: Keep session status as `SessionStatus.handshaking`, and transmit the local `CapabilitiesExchange` message encrypted.
*   **Incoming plaintexts**: On receiving `DomainCapabilitiesExchange`:
    *   Evaluate version range.
    *   Compute the intersection of local and remote capabilities.
    *   Store negotiated capability list in `PeerSession`.
    *   Transition session status to `SessionStatus.connected` (secure & ready).
    *   Trigger `_flushQueue()` to transmit queued messages.

---

## 10. Database Requirements

*   No SQLite database schema changes or migrations are needed. Capability negotiation is session-specific and maintained strictly in memory.

---

## 11. Security Invariants

*   Capabilities can never establish trust.
*   Capability negotiation cannot bypass Ed25519 signature checks.
*   Downgrade attacks are prevented by checking version policies inside the secure tunnel.

---

## 12. Failure / Recovery Matrix

| Failure Event | Expected State Transition | Recovery Action |
| :--- | :--- | :--- |
| **No common version** | Handshake rejected | Disconnect Nearby link, return protocol error. |
| **Negotiation timeout** | Session status failed | Disconnect transport endpoint, log error, and schedule backoff retry. |
| **Peer disconnects during exchange** | Session status disconnected | Clear session, resume background scanning. |
| **Unknown capability encountered** | Capability ignored | Map to `CAPABILITY_UNSPECIFIED`, proceed with common subsets. |

---

## 13. Automated Test Plan

### Test 1 — Version Negotiation (V1 ↔ V2)
A V2 device connects to a V1 device.
*   **Expected**: Handshake completes successfully, capability exchange is bypassed, negotiated version is set to 1, and messaging proceeds using `CAPABILITY_TEXT`.

### Test 2 — Version Negotiation (V2 ↔ V2)
Two V2 devices connect.
*   **Expected**: Handshake completes, capabilities are exchanged, session status becomes `connected`, queue flushes.

### Test 3 — Incompatible Versions
Device A (min=2, max=2) connects to Device B (min=1, max=1).
*   **Expected**: Connection rejected due to incompatible version range.

### Test 4 — Capability Intersection
Device A supports `[TEXT, IMAGE]` and Device B supports `[TEXT, FILE]`.
*   **Expected**: Negotiated capability is `[TEXT]`.

### Test 5 — Downgrade Protection
A malicious peer attempts to downgrade the session version below the minimum allowed version after handshake.
*   **Expected**: Handshake fails, transport disconnected.

---

## 14. Verification Checklist

- [ ] Protobuf compilation runs clean: `protoc --dart_out=...`
- [ ] Static analysis runs clean: `flutter analyze`
- [ ] All automated unit/widget/integration tests pass: `flutter test`
- [ ] Debug APK compiles successfully: `flutter build apk --debug`
