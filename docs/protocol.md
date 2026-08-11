# VANTRA — Protocol Specifications

## Phase Status

*   **Current Phase:** Phase 10
*   **Status:** Discovery candidate metadata hint protocol, auto-connect retry queues, and background auto-accept/verification completed.

---

## 1. Nearby Discovery Suffix Protocol

VANTRA coordinates background candidate discovery by embedding identity hints into the Nearby Connections local advertising name:
*   **Format:** `"$displayName:$peerId"`
*   **Delimiter:** `:` (colon).
*   **Construction:** The advertiser reads its local profile display name and UUID, formatted as `displayName:peerId`.
*   **Parsing:** The discoverer parses the advertising string:
    *   The prefix before the last colon is parsed as the `displayName`.
    *   The suffix after the last colon is resolved as the candidate `peerId`.
*   **Cryptographic Limitation:** This suffix is purely a candidate hint for database record lookup. The peer's identity is authenticated only during the subsequent `IdentitySecurePayload` handshake.

---

## 1. Protocol Buffers Wire Format

All data transmitted over the Nearby Connections transport is serialized using Protocol Buffers. The outer envelope is always a `VantraWireEnvelope` (version `1`).

### A. Outer Wire Envelope (`VantraWireEnvelope`)
```protobuf
message VantraWireEnvelope {
  uint32 protocol_version = 1;

  oneof payload {
    IdentitySecurePayload handshake = 2;
    EncryptedEnvelope encrypted_message = 3;
    ProtocolErrorPayload error = 4;
  }
}
```

---

### B. Secure Handshake Payload (`IdentitySecurePayload`)
Exchanged immediately when a connection transitions to the connected state.

```protobuf
message IdentitySecurePayload {
  string peer_id = 1;
  string display_name = 2;
  bytes identity_public_key = 3;  // 32 bytes Ed25519
  bytes ephemeral_public_key = 4; // 32 bytes X25519
  bytes signature = 5;            // 64 bytes Ed25519 signature
}
```

#### Canonical Handshake Transcript Bytes (Signed Input)
To prevent active signature spoofing, the handshake transcript is formatted into deterministic binary bytes before signing/verification:
1.  **Domain Separator:** `utf8.encode('VANTRA_HANDSHAKE_DOMAIN')` (23 bytes).
2.  **Protocol Version:** `v` mapped to a 4-byte big-endian unsigned integer (uint32).
3.  **Logical Identity (`peerId`):**
    *   2-byte big-endian length of the UTF-8 `peerId` string.
    *   Raw UTF-8 bytes of `peerId`.
4.  **Display Identity (`displayName`):**
    *   2-byte big-endian length of the UTF-8 `displayName` string.
    *   Raw UTF-8 bytes of `displayName`.
5.  **Long-Term Identity Key (`identityPublicKey`):**
    *   2-byte big-endian length of raw bytes (always 32).
    *   Raw bytes of the Ed25519 public key.
6.  **Ephemeral Key (`ephemeralPublicKey`):**
    *   2-byte big-endian length of raw bytes (always 32).
    *   Raw bytes of the X25519 ephemeral public key.

---

### C. Encrypted Wire Packet (`EncryptedEnvelope`)
Encapsulates all secure traffic (text messages, delivery acknowledgments, etc.) once the session is secure.

```protobuf
message EncryptedEnvelope {
  string message_id = 1;      // Unique ID for this specific packet
  string session_id = 2;      // Derived active session ID
  uint64 sequence = 3;        // Monotonic sequence number
  bytes nonce = 4;            // 12-byte AEAD nonce
  bytes ciphertext = 5;       // Encrypted VantraPlaintext bytes
  bytes mac = 6;              // 16-byte Poly1305 tag
}
```

*   **AEAD Associated Data (AAD):** The UTF-8 bytes of the envelope `message_id` are bound to the ciphertext as associated data.
*   **Nonce Generation:**
    *   *First 8 bytes (64 bits):* Concat of session salt.
    *   *Last 4 bytes (32 bits):* Monotonic sequence number in big-endian uint32 format.

---

### D. Decrypted Plaintext Payload (`VantraPlaintext`)
Contains the actual payload properties. This is encrypted inside `EncryptedEnvelope.ciphertext`.

```protobuf
message VantraPlaintext {
  string message_id = 1;      // Unique message UUID
  string session_id = 2;      // Session ID
  uint64 sequence = 3;        // Monotonic sequence number
  int64 timestamp_ms = 4;     // Epoch timestamp in milliseconds
  string sender_id = 5;
  string receiver_id = 6;

  oneof body {
    TextBody text = 7;
    AckBody ack = 8;
  }
}

message TextBody {
  string content = 1;
}

message AckBody {
  string original_message_id = 1;
  DeliveryStatus status = 2;
}

enum DeliveryStatus {
  DELIVERY_UNSPECIFIED = 0;
  DELIVERY_DELIVERED = 1;
}
```

---

## 2. Sequence, Replay & Session Validation

*   **Monotonic Counter Validation:** Incoming packets must have a `sequence` number strictly greater than the last successfully processed sequence number.
*   **Retransmission Invariant:** Retransmissions of a pending message (e.g. if the original ACK was lost) must use the **same logical messageId** but must be encrypted using a **new sequence number and nonce** under the current active session. This allows the packet to pass replay protection, and then trigger duplicate-message handling.

---

## 3. Encrypted ACK Invariant

*   Delivery ACKs are encrypted using the same session security parameters.
*   **Distinct Packet IDs:** Every ACK packet has its own unique outer `message_id` (representing the ACK packet itself) so that AAD binding and replay sequence tracking function normally. The ID of the original text message being acknowledged is placed inside `AckBody.original_message_id`.

---

## 4. Lost-ACK & Duplicate-Message ACK Recovery

*   If an incoming decrypted message has a `message_id` that is already present in the local database (indicating the remote peer retransmitted because it did not receive our ACK):
    1. The payload is discarded to prevent duplicate entries in SQLite and duplicate message bubbles in the UI.
    2. The encrypted ACK is immediately re-sent to the peer to clear their outgoing retry queue.
