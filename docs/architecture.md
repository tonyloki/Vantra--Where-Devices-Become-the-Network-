# VANTRA — Architecture Guide

## Phase Status

*   **Current Phase:** Phase 10
*   **Status:** Persistent trusted peer auto-reconnection, background auto-accept/auto-connect, and cryptographic validation completed.

---

## Implemented Architecture Layers

VANTRA uses a layered architecture to decouple presentation, business logic, data persistence, and transport details. The architecture features a dedicated **Cryptographic Security Layer** and a **Persistent Retry Queue** that wraps outgoing and incoming messages:

```text
               Presentation Layer (Flutter Widgets)
      [ChatPage / ConversationsPage / ContactsPage / SplashPage]
                                │
                                ▼
              Application State Layer (Riverpod Providers)
    [MessagingNotifier / conversationStreamProvider / peersProvider]
                                │
                                ▼
             Domain Service Layer (Encoding / Wire format)
     [MessagingService / ProtobufCodec / NearbyConnectionService]
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
- **SplashPage**: Plays a smooth fade-scale animation on the Vantra logo asset and coordinates non-blocking background initialization.
- **ConversationsPage**: Lists active chats with last message previews, status badges, unread count badges, and a green pulsing local network status indicator dot.
- **ChatPage**: Streams message history reactively. outgoing bubbles feature a violet-indigo gradient, while incoming bubbles match our dark slate card theme. Enforces input blocks when disconnected.
- **NearbyPeersPage**: Displays scanning radar animations, permission warnings, and discovered nearby endpoints.
- **ContactsPage**: Lists all encountered peers with filtering by trust states (All, Trusted, Blocked) and alphabetical headers.
- **OnboardingPage**: Redesigned responsive flow with transparent branding logo, clean P2P descriptions, and continue CTA.
- **MessagingNotifier**: Manages active handshakes, persistent retry queues, duplicate detection, and unread counters.

### 2. Domain & Wire format Service Layer
- **NearbyConnectionService**: The single global owner of the Nearby Connections lifecycle. Automatically boots discovery/advertising and manages app pause/resume background states.
- **MessagingService**: Prepares encrypted protobuf wire packets (`VantraWireEnvelope`) and transmits them across the Transport.
- **ProtobufCodec**: Handles binary encoding and decoding of protocol messages.
- **LocalIdentity**: Tracks local device UUID, display name, and private keys.

### 3. Cryptographic Security Layer
- **CryptoService**: Ephemeral Diffie-Hellman (X25519) key agreement, long-term Ed25519 signature checks, and HKDF-SHA256 session key derivation.
- **ChaCha20-Poly1305**: Encrypts and decrypts message bodies (`VantraPlaintext`) with Associated Data (AAD) binding using the packet `messageId`.
- **SecuritySession**: Tracks monotonic sequence counters (`sendSequence`, `receiveSequence`) and session key states in memory.

### 4. Local Persistence Data Layer
- **MessagingRepository**: Enforces duplicate message packet protection at database write time. Stores trusted peer public keys and fingerprints.
- **Drift / SQLite Database**: Persistent SQLite database (schema version 4) with support for message statuses, retry counts, read states, nicknames, and trust states.

### 5. Transport Layer
- **NearbyTransport**: Concrete implementation of `Transport` wrapper utilizing `nearby_connections` plugin for local P2P networking.
