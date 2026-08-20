# VANTRA — Protocol Specifications

## Phase Status

*   **Current Phase:** Phase 23: Android Background & Lifecycle
*   **Status:** Capabilities-based V2 version negotiation, connection recovery protection, direct-to-disk media streaming, mesh routing, voice recorder, voice message playback, audio call signaling, and group messaging protocol completed.

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

## 2. Protocol Buffers Wire Format

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
  
  // Protocol Version Range (Added in V2)
  uint32 min_supported_version = 6;
  uint32 max_supported_version = 7;
  repeated Capability supported_capabilities = 8;
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

> [!NOTE]
> **Backward Compatibility Transcript Invariant**: To ensure V1 devices can verify handshakes from V2 devices, the signature transcript is strictly computed over the first 5 fields only. The new V2 range and capability fields are appended to `IdentitySecurePayload` but are excluded from the signed transcript.

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
    CapabilitiesExchange capabilities_exchange = 9; // New in V2
    MediaControl media_control = 10;                // New in V2
    MediaChunk media_chunk = 11;                    // New in V2
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

message CapabilitiesExchange {
  uint32 min_supported_version = 1;
  uint32 max_supported_version = 2;
  repeated Capability supported_capabilities = 3;
}

message MediaControl {
  enum Type {
    TYPE_UNSPECIFIED = 0;
    OFFER = 1;
    ACCEPT = 2;
    REJECT = 3;
    CANCEL = 4;
  }
  Type type = 1;
  string transfer_id = 2;
  string file_name = 3;
  uint64 file_size = 4;
  string mime_type = 5;
  uint32 total_chunks = 6;
  uint32 chunk_size = 7;
  uint32 width = 8;
  uint32 height = 9;
  string caption = 10;
  uint32 next_expected_chunk = 11;
  string sha256 = 12;
}

message MediaChunk {
  string transfer_id = 1;
  uint32 chunk_index = 2;
  uint32 total_chunks = 3;
  bytes data = 4;
}
```

---

## 3. Sequence, Replay & Session Validation

*   **Sliding Window Replay Protection:** Incoming packets must pass a 64-packet sliding window check: the sequence number must be greater than `receiveSequence - 64`, and it must not have been previously received (no duplicates).
*   **Retransmission Invariant:** Retransmissions of a pending message (e.g. if the original ACK was lost) must use the **same logical messageId** but must be encrypted using a **new sequence number and nonce** under the current active session. This allows the packet to pass replay protection, and then trigger duplicate-message handling.

---

## 4. Encrypted ACK Invariant

*   Delivery ACKs are encrypted using the same session security parameters.
*   **Distinct Packet IDs:** Every ACK packet has its own unique outer `message_id` (representing the ACK packet itself) so that AAD binding and replay sequence tracking function normally. The ID of the original text message being acknowledged is placed inside `AckBody.original_message_id`.

---

## 5. Lost-ACK & Duplicate-Message ACK Recovery

*   If an incoming decrypted message has a `message_id` that is already present in the local database (indicating the remote peer retransmitted because it did not receive our ACK):
    1. The payload is discarded to prevent duplicate entries in SQLite and duplicate message bubbles in the UI.
    2. The encrypted ACK is immediately re-sent to the peer to clear their outgoing retry queue.

---

## 6. Protocol V2 Version Negotiation

VANTRA V2 introduces version negotiation to support backward compatibility with V1 devices.
1. **Version Range Advertisement**: The handshake payload (`IdentitySecurePayload`) includes `min_supported_version` and `max_supported_version`.
   * V1 devices omit these fields (implying version range `[1, 1]`).
   * V2 devices set range `[1, 2]`.
2. **Negotiation Logic**: Both peers calculate the intersection of their ranges:
   * `intersection = [max(local_min, remote_min), min(local_max, remote_max)]`
   * If the intersection is empty, the connection is aborted with error `NO_COMMON_VERSION`.
   * Otherwise, the negotiated version is the maximum value in the intersection: `negotiated_version = intersection.max`.
3. **Session Fallback**:
   * If `negotiated_version = 1`, the session runs in V1 mode. Capabilities default to `[text]`, and the `CapabilitiesExchange` packet is skipped.
   * If `negotiated_version = 2`, the session runs in V2 mode, proceeding to the Capabilities Exchange.

---

## 7. Capabilities Exchange Protocol

On a negotiated V2 session, the session status transitions to `SessionStatus.handshaking` (secure but not yet ready) until capability negotiation is complete.
1. **Capabilities Exchange Payload**: Both peers build a `CapabilitiesExchange` plaintext body containing their supported capabilities list and send it as sequence `1` on their outbound encrypted streams.
2. **Intersection Calculation**: Once a peer receives and processes the remote capabilities, it intersects them with its local advertised list. The resulting list is saved as `enabledCapabilities` on the `PeerSession`.
3. **Connection Recovery Check**: To prevent non-handshake packets (like ACKs or recovery payloads) from causing early status promotion without capabilities, the capability negotiator requires `enabledCapabilities != null` to confirm negotiation completion before transitioning status to `SessionStatus.connected`.

---

## 8. Secure Chunked Media/File Transfer Protocol

Arbitrary file and image transfers are coordinated offline using a structured control loop (OFFER -> ACCEPT/REJECT -> CHUNK -> ACK):

### A. Media OFFER
* Sender transmits a `MediaControl` packet of type `OFFER`. It contains `transferId`, `fileName`, `fileSize`, `mimeType`, `totalChunks`, `chunkSize`, and the `sha256` integrity hash.
* If it is an image, it also includes `width` and `height`.

### B. Media ACCEPT / REJECT
* The receiver validates if it supports the capability (`image` or `file`) and checks local space limits.
* If valid, the receiver checks if a transfer session exists. If resuming, it queries the number of unique received chunks to determine `nextExpectedChunk`.
* The receiver replies with a `MediaControl` packet of type `ACCEPT` containing `nextExpectedChunk`.
* If invalid, it replies with `REJECT`.

### C. Chunk Streaming (Direct-to-Disk)
* Upon receiving `ACCEPT`, the sender opens the source file once as a `RandomAccessFile` in read-only mode.
* The sender sequentially reads, encrypts, and sends segments of **128 KB** (or as advertised in the offer), ensuring a bounded memory footprint.
* The receiver opens a single `.tmp` file (e.g. `<appDocs>/media/temp/<transferId>.tmp`) using random-access I/O.
* As chunks arrive, the receiver seeks directly to the target offset `chunkIndex * chunkSize` and writes the decrypted bytes:
  ```dart
  await raf.setPosition(offset);
  await raf.writeFrom(chunkData);
  ```
* Out-of-order chunks are supported natively through sliding window replay protection updates.

### D. Final Integrity Check & Cleanups
* Once all unique chunks exist in the tracking set, the receiver closes the `.tmp` file.
* The receiver computes the SHA-256 hash of the complete `.tmp` file and verifies it against the expected hash.
* On success, the file is atomically renamed/moved to final storage:
  * Image: `<appDocs>/media/incoming/`
  * File: `<appDocs>/files/incoming/`
  * The message status in SQLite is updated to `received`, and a secure `ACK` is sent to the sender.
* On failure or timeout, the temporary file is deleted and resources are freed.
