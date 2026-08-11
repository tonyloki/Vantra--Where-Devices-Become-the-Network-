# VANTRA V2 — Phase 11: Protocol V2 & Capability Negotiation Implementation Plan (Revised)

This document details the final specification and implementation plan for Phase 11. It establishes a capability-aware, version-negotiating P2P communication layer (Protocol V2) while maintaining 100% backward compatibility with deployed V1 devices.

---

## 1. V1 ↔ V2 Compatibility Design (Crucial)

To prevent V1 devices from throwing validation errors when decoding handshake envelopes, we enforce the following rules:

### A. Envelope Compatibility
*   The outer wire envelope (`VantraWireEnvelope`) sent during handshake by a V2 device **MUST set its `protocol_version` field to `1`**. This ensures that V1 devices, which validate that the incoming version is $\le$ `kCurrentProtocolVersion` (which is `1` on V1), will not reject the packet.

### B. Handshake Transcript Encoding & Signature Invariant
*   The Ed25519 signature is computed over a manually encoded byte array of only the V1 fields (via `CanonicalEncoder.encodeHandshakeTranscript`).
*   In V2, we add new fields to the end of `IdentitySecurePayload` in Protobuf: `min_supported_version`, `max_supported_version`, and `supported_capabilities`.
*   Because Protobuf ignores unknown fields during parsing, a V1 device will successfully parse `IdentitySecurePayload`, verify the signature on the V1 fields, and establish the session.
*   A V2 device will parse the message, verify the signature on the V1 fields, and read the version range/capability properties.
*   **Transcript Isolation**: The signature is NEVER computed over the new fields directly during the handshake. This guarantees that V1 devices can successfully verify the handshake from a V2 device.

---

## 2. Separation of Version Concepts

The architecture strictly separates three version concepts:
1.  **Wire Version**: The structural encoding version of the envelope (represented in the `protocol_version` field of `VantraWireEnvelope`).
    *   Initiators/Advertisers send `protocol_version = 1` for the handshake.
    *   Once V2 is negotiated, subsequent secure messages use wire version `2`.
2.  **Supported Version Range**: The range of protocol versions the binary understands.
    *   V1 Device: `[1, 1]` (implied when fields are missing).
    *   V2 Device: `[1, 2]`.
3.  **Negotiated Session Version**: The deterministic single version calculated independently by both devices.
    *   Algorithm: `intersection = [max(local_min, remote_min), min(local_max, remote_max)]`.
    *   If `intersection` is empty: Handshake fails with `NO_COMMON_VERSION`, and the transport disconnects.
    *   Otherwise: `negotiated_version = intersection.max`.

---

## 3. Capability States & Registry

### A. Registry (Protobuf Enum)
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

### B. Capability Lifecycle States
*   **SUPPORTED**: Features implemented in the current code binary.
    *   *Phase 11*: `[CAPABILITY_TEXT]`.
*   **ADVERTISED**: Capabilities sent to the remote peer during handshake.
    *   *Phase 11*: `[CAPABILITY_TEXT]`.
*   **REMOTE_SUPPORTED**: Capabilities parsed from the remote handshake.
*   **NEGOTIATED**: The intersection of local `ADVERTISED` and remote `REMOTE_SUPPORTED` lists.
*   **ENABLED**: Active capabilities allowed for the current session.

---

## 4. State Machine & Session Negotiation

The session state machine progresses sequentially to prevent race conditions or unilateral downgrades:

```text
       SECURE_SESSION_ESTABLISHED (X25519 DH complete)
                    │
                    ▼
          NEGOTIATION_LOCAL_SENT
 (Send VantraPlaintext(CapabilitiesExchange) as seq 1)
                    │
                    ▼
        NEGOTIATION_REMOTE_RECEIVED
                    │
                    ▼
       NEGOTIATION_RESULT_CALCULATED
 (Verify exchange values match handshake fields)
                    │
                    ▼
           NEGOTIATION_COMPLETE
                    │
                    ▼
              SESSION_READY
                    │
                    ▼
               QUEUE_FLUSH
```

### Simultaneous Capability Messages
Both devices transmit their `CapabilitiesExchange` payload as sequence `1` in their respective directional streams. Receipt is processed asynchronously. The session only transitions to `SessionStatus.connected` once both messages have been successfully processed and verified.

### Legacy V1 Device Fallback
If the calculated negotiated version is `1` (which happens when connecting to a V1 peer):
1.  The V2 device immediately skips the `CapabilitiesExchange` state.
2.  Transitions directly to `connected` (secure & ready).
3.  Defaults negotiated capabilities to `[CAPABILITY_TEXT]`.
4.  Flushes queue.
This ensures V1 devices remain completely unaffected and do not receive unrecognized message types.

---

## 5. Security & Downgrade Protection

*   **Session Binding**: The capability exchange takes place entirely inside the encrypted, replay-protected, and sequence-verified channel using the derived X25519 session keys.
*   **Handshake Parameter Verification**: The decrypted `CapabilitiesExchange` message carries the version ranges and capability lists. Both sides verify that these values match the unencrypted handshake advertisements. If there is any discrepancy, the connection is immediately terminated.
*   **Malicious Downgrade Rejection**: A V2 peer cannot unilaterally command the other to "use V1" if the negotiated result (based on the intersected ranges) indicates V2.

---

## 6. Unknown Enum Handling

To handle future capabilities safely:
*   We map protobuf enum values using an explicit helper.
*   Any unrecognized capability integer maps to `null` and is filtered out (treated as unsupported and ignored).
*   Any explicit `CAPABILITY_UNSPECIFIED` is ignored.
*   Malformed or corrupted capability data fails validation and terminates the negotiation.

---

## 7. Protocol Message Design

We expand `vantra_message.proto` to include a new body type `CapabilitiesExchange`:

```protobuf
syntax = "proto3";

package vantra.protocol;

option java_package = "me.vantra.proto";
option java_outer_classname = "VantraProto";

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
  // New in V2:
  uint32 min_supported_version = 6;
  uint32 max_supported_version = 7;
  repeated Capability supported_capabilities = 8;
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

## 8. File-by-File Changes

### [vantra_message.proto](file:///c:/Users/Logesh/Documents/Vantra/proto/vantra_message.proto)
*   Add `CapabilitiesExchange` and `Capability` definitions.

### [protocol_version.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_version.dart)
*   Define `kCurrentProtocolVersion = 2` and `kMinSupportedProtocolVersion = 1`.

### [protocol_message.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protocol_message.dart)
*   Define `DomainCapabilitiesExchange` extending `DomainPlaintext`.
*   Expose `VantraCapability` in Dart.

### [protobuf_codec.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/protocol/protobuf_codec.dart)
*   Add serialization support for `DomainCapabilitiesExchange`.

### [messaging_provider.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/messaging/messaging_provider.dart)
*   Add state machine checks for `SessionStatus` during negotiation.
*   Enforce queue gating (flushing only after `negotiationComplete`).

---

## 9. Failure / Recovery Matrix

| Failure Event | Expected State Transition | Recovery Action |
| :--- | :--- | :--- |
| **No common version** | Reject handshake | Disconnect Nearby link, return protocol error. |
| **Negotiation timeout** | Reset session status | Disconnect transport endpoint, retry backoff. |
| **Tampered handshake values** | Disconnect | Terminate Nearby link immediately on mismatch detection. |

---

## 10. Automated Test Plan

### Test 1 — Version Negotiation (V1 ↔ V2)
*   Connect V2 and V1 devices.
*   **Expected**: negotiated version = 1, capability exchange bypassed, session ready, text messaging works.

### Test 2 — Version Negotiation (V2 ↔ V2)
*   Connect two V2 devices.
*   **Expected**: negotiated version = 2, capability exchange runs, session ready.

### Test 3 — Downgrade Protection
*   MITM modifies handshake range in transit.
*   **Expected**: Disconnect on CapabilitiesExchange validation mismatch.

---

## 11. Physical Device Verification Plan

1.  **V2 ↔ V2 Physical Test**: Verify auto-accept, negotiation, and message delivery.
2.  **V2 ↔ Deployed V1 Physical Test**: Run a device with the new V2 build against a device running the older Phase 10 build, ensuring no crashes occur and messaging works.
3.  **Automatic Reconnect**: Verify reconnection lifecycle triggers negotiation correctly.
