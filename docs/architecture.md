# VANTRA — Architecture Guide

## Phase Status

*   **Current Phase:** Phase 4
*   **Status:** Security model designed; waiting for implementation approval.

---

## Implemented Architecture Layers

VANTRA uses a layered architecture to decouple presentation, business logic, data persistence, and transport details. Phase 4 introduces a dedicated **Cryptographic Security Layer** that intercepts outgoing and incoming messages:

```text
               Presentation Layer (Flutter Widgets)
                     [ChatPage / PocPage]
                              │
                              ▼
            Application State Layer (Riverpod Providers)
           [MessagingNotifier / conversationStreamProvider]
                              │
                              ▼
           Domain Service Layer (Encoding / Wire format)
                     [MessagingService]
                              │
                              ▼
                 Cryptographic Security Layer
                [Cryptography / Key Agreement]
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
       Transport Layer                 Data Layer (Repository)
     [NearbyTransport]             [MessagingRepository]
              │                               │
              ▼                               ▼
      Nearby Connections               Drift DAO Layer
    (P2P Hardware Radios)              [MessageDao / PeerDao]
                                              │
                                              ▼
                                        SQLite Database
```

### 1. Presentation & State Layer
*   **ChatPage:** Subscribes to `conversationStreamProvider(peerId)` which streams database changes reactively. Displays security fingerprints. Locks message input automatically if session status disconnects.
*   **PocPage:** Displays advertising, discovery, connection logs, and unified active connection statuses.
*   **MessagingNotifier:** Manages peer handshake triggers, key agreement setup, and handles sending logic (pending -> transmit -> sent/failed).

### 2. Domain & Wire format Service Layer
*   **MessagingService:** Responsible for serialization/deserialization of JSON packets (handshake and encrypted wrappers).
*   **LocalIdentity:** Tracks device UUID and displayName using `SharedPreferences`, and long-term private keys via `flutter_secure_storage`.

### 3. Cryptographic Security Layer
*   **ECDH X25519 & Ed25519:** Handles ephemeral key agreement and long-term peer signature verification during the handshake.
*   **ChaCha20-Poly1305:** Encrypts and decrypts text message payloads. Enforces authenticity checks using associated data binding.

### 4. Local Persistence Data Layer
*   **MessagingRepository:** Acts as a clean boundary wrapping SQLite queries. Enforces duplicate message packet protection at database write time. Stores trusted peer public keys and fingerprints.
*   **Drift / SQLite Database:** Manages local persistence for messages and known peers.
*   **Memory Isolation:** Automated tests utilize `NativeDatabase.memory()` to spin up isolated database instances.

### 5. Transport Layer
*   **NearbyTransport:** Concrete implementation of `Transport` wrapper utilizing `nearby_connections` plugin for local P2P networking.
