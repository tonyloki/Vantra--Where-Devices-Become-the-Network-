# VANTRA — Security Threat Model

This document outlines the security threats analyzed for VANTRA's peer-to-peer (P2P) communication architecture and specifies how Phase 14 mitigations protect the system.

---

## Threat Matrix & Analysis

### 1. Passive Eavesdropper
*   **Description:** An attacker intercepts radio transmissions over the air (Wi-Fi/Bluetooth) to read message content.
*   **Phase 4 Mitigation:** Fully protected. Ephemeral Diffie-Hellman key agreement (X25519) establishes a shared secret, and messages are encrypted using ChaCha20-Poly1305 AEAD. Eavesdroppers only see encrypted wrappers and nonces.
*   **Limitations:** Ed25519/X25519 operations are executed via the package's optimized pure-Dart implementation (since standard Android Java providers lack built-in support for Curve25519 until API 31/33). Native platform acceleration is utilized for ciphers and hashing where supported.

### 2. Malicious Nearby Device
*   **Description:** A rogue nearby device tries to connect to one of the VANTRA nodes to read or inject messages.
*   **Phase 4 Mitigation:** Fully protected. The rogue device cannot decrypt messages without the derived session key. It cannot perform a successful secure handshake under an impersonated ID without possessing the corresponding private signature key.

### 3. Packet Modification / Tampering
*   **Description:** An attacker intercepts a packet over the air, modifies the bytes, and forwards it to the recipient.
*   **Phase 4 Mitigation:** Fully protected. ChaCha20-Poly1305 is an AEAD construction. If even a single bit of the ciphertext or the associated data (`messageId` bound as AD) is altered, Poly1305 tag verification fails, decryption throws a cryptographic exception, and VANTRA drops the packet immediately.

### 4. Replay Attack
*   **Description:** An attacker intercepts a valid encrypted packet and transmits it again later to induce duplicate message rendering.
*   **Phase 4 Mitigation:** Fully protected via per-session monotonic sequence checks:
    *   *Cross-Session Replays:* Ephemeral session keys change on every connection, making older session replays fail decryption.
    *   *Intra-Session Replays:* Each message contains an encrypted `seq` number and a `sessionId`. The recipient rejects any packet where `seq <= lastReceiveSequence` or where the `sessionId` does not match the active session.
*   **Limitations:** None. Replay protection is independent of system clock timestamps.

### 5. Impersonation
*   **Description:** An attacker attempts to connect to Device B claiming to be Device A (`peerId` or `displayName`).
*   **Phase 4 Mitigation:** Protected. If Device B has already stored A's public identity key, it verifies the handshake signature using the stored key. If signature check fails or the public key does not match, B rejects the connection.
*   **Limitations:** Only works after trust has been established. Does not protect against initial impersonation on first connect if the user accepts the remote peer without verifying its fingerprint.

### 6. Compromised Local Storage (Rooted Device)
*   **Description:** An attacker gains access to the local SQLite database file on a rooted device.
*   **Phase 4 Mitigation:** Out of scope for Phase 4. Messages are persisted in plaintext SQLite databases in the application sandbox. Plaintext-at-rest protection is deferred to future phases (e.g. SQLCipher).

### 7. Stolen Device
*   **Description:** The physical device is stolen by an attacker.
*   **Phase 4 Mitigation:** Protected. Long-term identity private-key material is protected using `flutter_secure_storage` and Android Keystore-backed encrypted storage.
*   **Limitations:** If the user has no lockscreen password/PIN, the attacker can launch VANTRA and read history.

### 8. EndpointId Spoofing / Connection Confusion
*   **Description:** An attacker spoofing its Nearby Connection `endpointId` to trick the application into matching it to a trusted peer session.
*   **Phase 4 Mitigation:** Fully protected. VANTRA maps a temporary `endpointId` to a persistent `peerId` only after the secure handshake successfully completes and remote signatures are verified.

### 9. Display-Name Spoofing
*   **Description:** A rogue user creates a device named `Alice` (the name of B's trusted contact) to trick the user.
*   **Phase 4 Mitigation:** Partially protected. The display name is cryptographically signed during the handshake. However, display name uniqueness is not checked. Users must compare fingerprints to verify cryptographic identity uniqueness.

### 10. Key Replacement (MITM on Initial Exchange)
*   **Description:** During the first connection, a MITM attacker intercepts public keys and injects their own keys.
*   **Phase 4 Mitigation:** Mitigated via out-of-band fingerprint verification. Cryptographic signatures prove possession of the advertised identity private key, but first-contact MITM protection depends on authenticating the public key fingerprint.
*   **Limitations:** If users skip comparing fingerprints, a MITM attacker can succeed. If fingerprints are not verified, the MITM vulnerability remains.

### 11. Reconnect with Changed EndpointId
*   **Description:** A legitimate peer disconnects and reconnects, obtaining a different Nearby `endpointId`.
*   **Phase 4 Mitigation:** Fully protected. Reconnections trigger a fresh secure handshake and signature verification using the long-term identity public key, ensuring continuity of identity.

### 12. Malformed Encrypted Payload
*   **Description:** An attacker sends random bytes to trigger crashes or memory leaks.
*   **Phase 4 Mitigation:** Fully protected. Decryption fails gracefully. Exceptions are caught, diagnostic logs are generated (with no sensitive data), and the invalid packet is discarded.

### 13. Nonce Reuse
*   **Description:** Encrypting two different messages with the same key and the same nonce.
*   **Phase 4 Mitigation:** Fully protected. VANTRA implements a deterministic counter-based nonce construction where the nonce is derived from the session parameters and the monotonic `sendSequence` counter. Nonce uniqueness under the current session key is guaranteed.

### 14. Random Number Generation Failure
*   **Description:** The system's random number generator becomes predictable.
*   **Phase 4 Mitigation:** Protected. The `cryptography` package utilizes native platform CSPRNGs. If platform entropy fails, the package throws an exception, refusing to generate keys.

### 15. Protocol Downgrade Attack (MITM Version Spoofing)
*   **Description:** An attacker intercepts the handshake and claims the peer only supports version 1 to force a downgrade to a lower security protocol.
*   **Phase 14 Mitigation:** Fully protected.
    *   *No Fallback from Secure to Plaintext*: There is no automatic fallback from the secure protocol to plaintext. Any plaintext message or unsupported version payload received is rejected, and the connection is closed.
    *   *Version Negotiation Invariant*: Version ranges are validated. A V2 device will calculate a negotiated version of `2` when connecting to another V2 device.
    *   *Downgrade Protection (Spoofing Detection)*: Once a V2 device establishes a peer relationship with another V2 device, it persists the peer's capability details. If the same peer subsequently attempts a connection claim representing itself as V1, the system flags the version downgrade discrepancy as a potential spoofing attempt, aborts the connection request, and refuses to derive session keys.

