# VANTRA — Architecture Guide

## Phase Status

*   **Current Phase:** Phase 7
*   **Status:** Secure direct P2P messaging core, Discovery, Contacts, Trust Management, and Retry Queue completed.

---

## Implemented Architecture Layers

VANTRA uses a layered architecture to decouple presentation, business logic, data persistence, and transport details. The architecture features a dedicated **Cryptographic Security Layer** and a **Persistent Retry Queue** that wraps outgoing and incoming messages:

```text
               Presentation Layer (Flutter Widgets)
            [ChatPage / ConversationsPage / ContactsPage]
                               │
                               ▼
             Application State Layer (Riverpod Providers)
       [MessagingNotifier / conversationStreamProvider / peersProvider]
                               │
                               ▼
            Domain Service Layer (Encoding / Wire format)
            [MessagingService / ProtobufCodec / Protobuf]
                               │
                               ▼
                  Cryptographic Security Layer
                 [CryptoService / SecuritySession]
                               │
               ┌───────────────┴───────────────┐
               ▼                               ▼
        Transport Layer                 Data Layer (Repository)
      [NearbyTransport]             [MessagingRepository]
               │                               │
               ▼                               ▼
       Nearby Connections               Drift DAO Layer
     (P2P Hardware Radios)          [MessageDao / PeerDao]
                                               │
                                               ▼
                                         SQLite Database
```

### 1. Presentation & State Layer
*   **ChatPage:** Subscribes to `conversationStreamProvider(peerId)` which streams database changes reactively. Displays security trust shields, local nickname renames, and a blocked banner if the peer is distrusted.
*   **ConversationsPage:** Lists active chats with last message previews, status badges (pending, sent, delivered), unread count badges, and online presence indicators.
*   **NearbyPeersPage:** UI control center for Nearby Connection advertising and discovery. Matches found endpoints with known database profiles.
*   **ContactsPage:** Persistent directory of all encountered peers with filtering by trust state (All, Trusted, Blocked) and nickname search.
*   **MessagingNotifier:** Manages peer handshake triggers, key agreement setup, persistent retry queues, duplicate detection, and unread counters.

### 2. Domain & Wire format Service Layer
*   **MessagingService:** Prepares encrypted protobuf wire packets (`VantraWireEnvelope`) and transmits them across the Transport.
*   **ProtobufCodec:** Handles binary encoding and decoding of protocol messages.
*   **LocalIdentity:** Tracks local device UUID, display name, and private keys.

### 3. Cryptographic Security Layer
*   **CryptoService:** ECDH X25519 ephemeral key agreement, long-term Ed25519 signature checks, and HKDF-SHA256 session key derivation.
*   **ChaCha20-Poly1305:** Encrypts and decrypts message bodies (`VantraPlaintext`). Enforces Associated Data (AAD) binding using the packet `messageId`.
*   **SecuritySession:** Tracks monotonic sequence counters (`sendSequence`, `receiveSequence`) and session key states in memory.

### 4. Local Persistence Data Layer
*   **MessagingRepository:** Provides a clean interface to query peers and messages. Enforces duplicate message packet protection at database write time. Stores trusted peer public keys and fingerprints.
*   **Drift / SQLite Database:** Persistent SQLite database (schema version 4) with support for message statuses, retry counts, read states, nicknames, and trust states.

### 5. Transport Layer
*   **NearbyTransport:** Concrete implementation of `Transport` wrapper utilizing `nearby_connections` plugin for local P2P networking.
