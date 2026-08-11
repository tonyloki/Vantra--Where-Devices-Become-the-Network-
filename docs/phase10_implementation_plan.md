# VANTRA V2 — Phase 10: Persistent Trusted Peer Auto-Reconnection Implementation Plan

This implementation plan details the architecture, state machine, cryptographic sessions, and file-by-file changes required to enable automatic reconnection between previously trusted VANTRA peers without manual user intervention or repeated verification prompts.

---

## 1. Current Phase 1–9 Architecture Audit

*   **P2P Transport**: Leverages Google Nearby Connections via `nearby_connections` wrapped by `NearbyTransport`.
*   **Global Connection Lifecycle**: Owned strictly by `NearbyConnectionService`, which coordinates background discovery and advertising based on the Android app lifecycle.
*   **State Machine**:
    *   `NearbyConnectionState` tracks the status of the native service (`initializing`, `permissionsRequired`, `locationDisabled`, `ready`, `error`).
    *   `MessagingState` maintains a map of `sessions` (`PeerSession`) and `endpointToPeerId` to route messages and security sessions.
    *   `ConnectionStatus` tracks Nearby-level connection status (`idle`, `connecting`, `connected`, `disconnected`, etc.).
*   **Cryptographic Layer**: Enforces persistent Ed25519 identity keys, fresh X25519/ECDH ephemeral exchange on connected sockets, HKDF session key derivation, and ChaCha20-Poly1305 directional encryption.
*   **Queueing**: Phase 7 persistent messaging queue stores pending/failed messages in SQLite (via `MessagingRepository` / Drift) and flushes them sequentially in FIFO order upon transition to a secure session.

---

## 2. Terminology and Identity Resolution Strategy

To maintain clear security boundaries, VANTRA distinguishes between five identity constructs:
1.  **Discovery Identity Hint**: The untrusted `peerId` metadata advertised in the Nearby name (`displayName:peerId`). It is used strictly as a transport candidate hint to locate trusted peer records.
2.  **Transport Endpoint Identity**: The temporary `endpointId` assigned by Nearby Connections. This mapping changes frequently and is never used as persistent proof of identity.
3.  **Persistent Cryptographic Identity**: The persistent Ed25519 public key. This is the sole source of truth for authenticating a peer.
4.  **Trust State**: The locally stored relationship state (`trusted`, `untrusted`, `distrusted`) in the database mapped to the persistent Ed25519 public key.
5.  **Secure Session Identity**: The derived unique session parameters (Session ID, symmetric keys, salts) bound to a single active connection lifetime.

> [!IMPORTANT]
> **Identity Discovery Security Boundary**: The advertised `peerId` parsed from the discovery name is ONLY a discovery hint / candidate identifier. It is NOT cryptographic proof of identity and MUST NEVER establish trust. Because a malicious actor could advertise a spoofed `peerId` (e.g. `"Tony:trusted-peer-uuid"`), the application MUST NOT consider the peer trusted merely because the advertised `peerId` matches a database entry. Secure session establishment and message exchange depend entirely on the subsequent cryptographic handshake.

---

## 3. Revised Automatic Reconnection Flow

```text
Trusted peer candidate discovered
        ↓
Read advertised peerId as a candidate hint
        ↓
Look up local trust state
        ↓
   TRUSTED?
   /      \
 NO        YES
 ↓          ↓
Normal    Auto-connect
pairing      ↓
           Nearby connection request
                ↓
           Remote side receives request
                ↓
           Candidate peerId parsed
                ↓
           Local trust lookup
                ↓
           TRUSTED?
                ↓
           Auto-accept
                ↓
           Nearby CONNECTED
                ↓
           IDENTITY_SECURE handshake
                ↓
           Ed25519 signature verification
                ↓
           Compare presented public key
           against stored trusted public key
                ↓
          MATCH?
          /     \
        NO       YES
        ↓         ↓
   Reject +     Fresh X25519
   security        ↓
   warning       Fresh HKDF
                    ↓
              New SecuritySession
                    ↓
                 SECURE
                    ↓
              Flush queue
```

---

## 4. Explicit Security Invariants

### Discovery Identity Security Invariant
*   `endpointId` is temporary.
*   Advertised `peerId` is untrusted metadata.
*   Stored `peerId + publicKey` represents the persistent identity relationship.
*   Only the signed `IDENTITY_SECURE` handshake authenticates the peer.
*   A matching advertised `peerId` MUST NOT bypass cryptographic verification.

### Trusted Reconnection Invariant
*   A trusted peer may automatically bypass the USER CONFIRMATION UI, but it may NEVER bypass cryptographic authentication.
*   **"No repeated user verification" does NOT mean "No repeated cryptographic verification."**
*   Every reconnection must still perform a secure handshake. Old session keys must remain destroyed after disconnect, and new session keys must be derived using fresh ephemeral keys.

---

## 5. Identity Mismatch Handling

If the advertised `peerId` matches a trusted record, but the presented Ed25519 public key does NOT match the stored public key during the handshake:
1.  **Do NOT derive session keys** or enter the `SECURE` session state.
2.  **Disconnect the Nearby endpoint** immediately.
3.  **Do NOT modify the existing trusted record automatically** (do not overwrite the public key or update the trust state automatically).
4.  **Mark the connection as an identity-security event** in the application state.
5.  **Show the security warning UI** to the user.
6.  **Require explicit user action** (manually re-verify the fingerprint or keep the peer blocked) before any modifications to trust or public key records are allowed in the database.

---

## 6. Auto-Accept Logic (Initiator vs. Responder)

### Initiator
When a trusted candidate peer is discovered and no active connection exists, the initiator automatically starts the connection request via `PeerDiscoveryService.connect()`, passing its own identity hint suffix.

### Responder
When a Nearby connection request arrives:
1.  Read the advertised candidate `peerId` from the request.
2.  Treat it only as an untrusted hint.
3.  Look up the corresponding local peer record in the database.
4.  If the local peer is `TRUSTED`, accept the connection request programmatically in the background without displaying the manual pairing overlay.
5.  Once Nearby reports `CONNECTED`, perform the normal cryptographic handshake.
6.  Only after successful Ed25519 identity verification and public-key matching may the session become `SECURE`.
*   *Note*: If the candidate is unknown/untrusted, retain the existing manual pairing flow (requires user acceptance and authentication token verification). If `distrusted` (blocked), reject the connection request immediately.

---

## 7. Preservation of Cryptographic Architecture

Phase 10 is restricted to the connection lifecycle and must **NOT** modify or weaken the security layer. The following cryptographic systems remain unchanged:
*   Ed25519 identity generation/storage.
*   Canonical handshake signing.
*   Ed25519 signature verification.
*   X25519 ephemeral key exchange.
*   HKDF-SHA256 derivation.
*   Lexicographical directional key assignment.
*   ChaCha20-Poly1305 encryption.
*   12-byte counter nonce construction.
*   `messageId` Associated Authenticated Data (AAD) binding.
*   Session ID validation.
*   Monotonic sequence/replay protection.
*   Encrypted ACKs.
*   Phase 7 duplicate prevention.

---

## 8. Connection State Machine

```text
    DISCOVERING
         ↓
    TRUST_HINT_RESOLUTION
         ↓
    ┌───────────────┐
    │               │
 UNKNOWN/UNTRUSTED  TRUSTED
    │               │
    ↓               ↓
PAIRING_REQUIRED  AUTO_CONNECT
                    ↓
                 CONNECTING
                    ↓
                 AUTHENTICATING
                    ↓
              IDENTITY VERIFIED
                    ↓
                KEY_DERIVING
                    ↓
                  SECURE
                    ↓
              QUEUE_FLUSHING
                    ↓
                  ONLINE

Identity Mismatch Pathway:

    AUTHENTICATING
          ↓
    IDENTITY_MISMATCH
          ↓
    DISCONNECT
          ↓
    SECURITY WARNING (Awaiting explicit user trust modification)
```

---

## 9. File-by-File Modifications

### [NearbyConnectionService](file:///c:/Users/Logesh/Documents/Vantra/lib/core/networking/nearby_connection_service.dart)
*   Update `initialize()` and `_resumeNearbyOperations()` to format the local advertising name as `"$displayName:${localIdentity.peerId}"`.

### [PeerDiscoveryService](file:///c:/Users/Logesh/Documents/Vantra/lib/core/peers/peer_discovery_service.dart)
*   Modify `_onDiscoveredPeers` to parse the `displayName` and `peerId` from the discovered name (`displayName:peerId`) and populate `resolvedPeerId` in `DiscoveredNearbyPeer`.

### [MessagingNotifier](file:///c:/Users/Logesh/Documents/Vantra/lib/core/messaging/messaging_provider.dart)
*   **Watch Discovered Peers**: Watch the `discoveredNearbyPeersProvider` stream.
*   **Auto-Connect Loop**: Add background connection triggering:
    *   Iterate through discovered trusted peers.
    *   If a trusted peer is disconnected and not currently connecting/handshaking, and the reconnect cooldown has elapsed, trigger `PeerDiscoveryService.connect()`.
*   **Background Auto-Accept**: Modify `_handleConnectionUpdate()`:
    *   On `connecting`: Parse `peerId` from `update.endpointName`. If the peer is `TRUSTED`, automatically invoke `acceptConnection(update.endpointId)` without populating `activeConnectionRequest`.
    *   Otherwise, display the verification overlay as normal.
*   **Handshake Public Key Verification**: Inside `_handleSecureIdentityReceived()`:
    *   Validate the incoming public key matches the stored public key for the peer.
    *   If mismatched, terminate key derivation, set `identityMismatchRequest` in `MessagingState`, and surface a warning.
*   **Cooldown and Backoff Map**: Track `_lastConnectAttempt = <String, DateTime>{}` and `_reconnectBackoff = <String, Duration>{}` to enforce exponential backoff (e.g., 5s, 10s, 20s, 40s, max 60s) on failed connection attempts.

### [GlobalConnectionListener](file:///c:/Users/Logesh/Documents/Vantra/lib/main.dart)
*   Observe `state.identityMismatchRequest` inside the listener.
*   If set, display a red-alert backdrop sheet showing:
    > "⚠ Security change detected
    > The identity of this device does not match the identity you previously trusted.
    > [Verify again] [Keep blocked]"
*   Hook up `Verify again` to reset trust state to `untrusted` and proceed to manual pairing, and `Keep blocked` to block the peer (`distrusted`) and disconnect.

### [ChatPage](file:///c:/Users/Logesh/Documents/Vantra/lib/features/messaging/chat_page.dart)
*   Modify the text input and send button `enabled` property to be `(isTrusted || isConnected) && !isBlocked`. This allows users to compose and queue messages for trusted peers while offline.

---

## 10. Failure / Recovery Matrix

| Failure Event | Expected State Transition | Recovery Action |
| :--- | :--- | :--- |
| **Trusted peer goes offline** | Session status transitions to `disconnected` / `failed` | Clear session in memory, set reconnect backoff timer, and resume background scanning. |
| **Handshake timeout** | Session status transitions to `failed` | Disconnect transport endpoint, log error, and schedule backoff retry. |
| **Signature verification fails** | Disconnect immediately | Drop all packets, log security warning, and prevent session creation. |
| **Public key mismatch** | Session status blocked, display warning | Halt handshake, clear session, and show the security mismatch overlay. |
| **Location disabled mid-run** | `locationDisabled` | Suspend discovery/advertising and show status banner. |
| **App killed during reconnect** | Offline (`disconnected`) | On next app launch, Nearby service restarts scanning and resumes auto-connect loop. |
| **Simultaneous connection requests** | `connecting` | Nearby handles parallel connection requests; both sides auto-accept and perform a single handshake. |
| **Stale Endpoint reported** | Transport error on connect | Update backoff cooldown, clean discovered maps, and wait for fresh discovery. |

---

## 11. UI / UX Design

### Chat Header Status
*   **Securely Connected**: `"Tony ● Secure"` (Green dot).
*   **Reconnecting**: `"Tony ↻ Connecting..."` (Amber rotating indicator/text).
*   **Offline**: `"Tony ○ Offline (Last seen: ...)"` (Muted gray text).

### Mismatch Warning Overlay
Displayed globally when `state.identityMismatchRequest != null`:

```text
+---------------------------------------------------+
|            ⚠ Security change detected            |
|                                                   |
|  The identity of this device does not match the   |
|  identity you previously trusted.                 |
|                                                   |
|    [ Verify again ]          [ Keep blocked ]     |
+---------------------------------------------------+
```

---

## 12. Logging & Diagnostics

Standardized logs to output via console (without logging private keys, session keys, or plain text):
*   `[VANTRA][NEARBY] AUTO_RECONNECT peerId=... endpointId=...`
*   `[VANTRA][NEARBY] TRUSTED_PEER_DISCOVERED peerId=... name=...`
*   `[VANTRA][NEARBY] ENDPOINT_RESOLVED endpointId=... peerId=...`
*   `[VANTRA][NEARBY] CONNECT_ATTEMPT endpointId=...`
*   `[VANTRA][NEARBY] IDENTITY_MATCH peerId=...`
*   `[VANTRA][NEARBY] IDENTITY_MISMATCH peerId=... oldKey=... newKey=...`
*   `[VANTRA][NEARBY] RECONNECT_BACKOFF peerId=... delaySeconds=...`

---

## 13. Automated Test Plan

### Test A — Spoofed advertised peerId
An attacker advertises `peerId = trusted-peer-id` but uses a different Ed25519 identity key.
*   **Expected**: Connection may begin → Handshake fails due to public-key mismatch → No session derived → No message delivery.

### Test B — Genuine trusted peer
Advertised `peerId` matches, and the Ed25519 public key matches the stored identity.
*   **Expected**: Automatic connection → Handshake succeeds → Fresh session derived → Status `SECURE` → Outgoing queue flushes.

### Test C — Endpoint ID changes
Same trusted peer moves to a new endpoint (old `endpointId` = X, new `endpointId` = Y).
*   **Expected**: Peer still recognized by persistent identity, auto-reconnect successfully establishes a fresh secure session.

### Test D — Changed identity
Same advertised `peerId` but a new Ed25519 public key is presented.
*   **Expected**: Connection rejected, transport disconnected, no session keys derived, security warning displayed, and existing trusted record remains unchanged.

### Test E — Unknown peer
Unknown advertised `peerId`.
*   **Expected**: No automatic trust, falls back to manual pairing flow.

### Test F — Distrusted peer
Distrusted `peerId` attempts connection.
*   **Expected**: Connection rejected immediately, no handshake performed, no session created.

---

## 14. Performance & Resource Considerations

*   **Battery Footprint**: Advertising and discovery are suspended when the app goes into the background, and resume in the foreground.
*   **Cooldown**: Exponential backoff prevents rapid connection retries from burning CPU and battery.
*   **Connection Limits**: Limits background connections to one active handshake attempt at a time.

---

## 15. Risks and Mitigations

*   **Risk**: Nearby Connections sometimes fails to establish socket connections on the first attempt due to transient hardware interference.
    *   *Mitigation*: The app uses backoff retries to automatically attempt reconnection once the transient state clears.
*   **Risk**: Display name collisions (e.g. multiple devices advertise as `"Tony"`).
    *   *Mitigation*: The connection coordinator differentiates peers based on the unique `peerId` suffix, ignoring name duplicates.

---

## 16. Verification Checklist

- [ ] Static analysis runs clean: `flutter analyze`
- [ ] All automated unit/widget/integration tests pass: `flutter test`
- [ ] Debug APK compiles successfully: `flutter build apk --debug`
- [ ] Physical verification of Auto-Connect completed.
- [ ] Physical verification of Identity Mismatch warnings completed.
- [ ] Physical verification of Offline Queue flushing completed.
