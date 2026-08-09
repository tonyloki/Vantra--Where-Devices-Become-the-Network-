# VANTRA — Architecture Guide

## Phase Status

*   **Current Phase:** Phase 3
*   **Status:** Offline-First SQLite Local Messaging Persistence.

## Implemented Architecture Layers

VANTRA uses a layered architecture to decouple presentation, business logic, data persistence, and transport details:

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
*   **ChatPage:** Subscribes to `conversationStreamProvider(peerId)` which streams database changes reactively. Locks message input automatically if session status disconnects.
*   **PocPage:** Displays advertising, discovery, connection logs, and unified active connection statuses.
*   **MessagingNotifier:** Manages peer handshake triggers and handles sending logic (pending -> transmit -> sent/failed).

### 2. Domain & Wire format Service Layer
*   **MessagingService:** Responsible for serialization/deserialization of JSON packets (IDENTITY and TEXT).
*   **LocalIdentity:** Tracks device UUID and displayName using `SharedPreferences`.

### 3. Local Persistence Data Layer
*   **MessagingRepository:** Acts as a clean boundary wrapping SQLite queries. Enforces duplicate message packet protection at database write time.
*   **Drift / SQLite Database:** Manages local persistence for messages (ordered chronologically by database primary key `localId` to preserve exact arrival sequence) and known peers.
*   **Memory Isolation:** Automated tests utilize `NativeDatabase.memory()` to spin up isolated database instances.

### 4. Transport Layer
*   **NearbyTransport:** Concrete implementation of `Transport` wrapper utilizing `nearby_connections` plugin for local P2P networking.
