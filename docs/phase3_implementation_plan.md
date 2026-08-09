# Phase 3: Offline-First Local Messaging Persistence Implementation Plan

This plan documents the design and migration path for introducing local database persistence using Drift + SQLite in VANTRA.

---

## 1. Current Architecture

At the end of Phase 2, real-time message exchange was fully operational using Nearby Connections and in-memory message history tracking:

```text
NearbyTransport (Nearby Connections wrapper)
       ↓ (connectionUpdateStream, payloadReceivedStream)
MessagingService (Encodes/decodes TEXT & IDENTITY payloads)
       ↓ (messageStream, identityStream)
MessagingNotifier (Riverpod Notifier managing maps of sessions & messageHistory in memory)
       ↓ (Exposes MessagingState)
ChatPage & PocPage (UI widgets subscribing to messagingStateProvider)
```

**Known Limitation:** All messages, mapped peer sessions, and temporary routing endpoint connections vanish when the app restarts, closes, or when navigation occurs away from the active UI context.

---

## 2. Refined Architectural & Implementation Guidelines

### 1. Message Status Representation
To avoid raw status strings scattered across the codebase, we define a domain enum `MessageStatus` in our Dart code:

```dart
enum MessageStatus {
  pending,
  sent,
  received,
  failed,
}
```

In the Drift schema, we utilize Drift's built-in `textEnum<MessageStatus>()` mapping to serialize/deserialize this enum to/from strings in SQLite safely.

*Definition of 'Sent':* A message status becomes `sent` immediately after `Transport.send()` completes successfully from the perspective of the local device. It does *not* imply remote delivery confirmation or read acknowledgement.

### 2. Message ID Uniqueness & Duplicate Protection
*   **Database Constraint:** We add a UNIQUE index or primary key constraint on `messageId` in our Drift `Messages` table definition to reject any duplicates.
*   **Repository Safeguard:** The repository will check if a message with the given `messageId` already exists before inserting incoming messages. If a duplicate payload is received, the write is ignored, ensuring exactly one database row and one UI bubble.

### 3. Test Database Strategy
*   All unit and widget tests will execute against an isolated in-memory Drift database constructed via `DatabaseConnection(InMemoryDatabase())` or utilizing `drift_dev`'s custom in-memory testing constructors.
*   Unit tests will never write to or read from the user's physical Android SQLite database. Each test case will instantiate and dispose of its own database instance.

### 4. Conversation Query and Ordering
*   **Bilateral Query:** The conversation query will pull messages in both directions:
    ```sql
    (senderId == localPeerId AND receiverId == remotePeerId)
    OR
    (senderId == remotePeerId AND receiverId == localPeerId)
    ```
*   **Local Sequence Ordering:** Displayed messages will be ordered chronologically according to local database insertion order using the `localId` (the auto-incrementing SQLite primary key) or local `createdAt` timestamp. We do *not* use remote timestamps as the primary ordering mechanism to ensure sequence preservation.

### 5. Peer Identity Separation
*   We preserve the separation of `persistent peerId` (identifies the device across sessions) and `temporary Nearby endpointId` (rotates on discovery).
*   Upon peer reconnection, the application upserts the peer in the database, updating their `lastKnownEndpointId` and `lastSeen` values under the same persistent `peerId`. This guarantees that historical messages linked to the `peerId` remain visible and connected.

---

## 3. Database Schema

### 1. Messages Table (`messages.dart`)
*   `localId` (`IntColumn`, Auto-Increment Primary Key)
*   `messageId` (`TextColumn`, Unique)
*   `senderId` (`TextColumn`)
*   `receiverId` (`TextColumn`)
*   `text` (`TextColumn`)
*   `timestamp` (`IntColumn`)
*   `type` (`TextColumn`)
*   `status` (`TextColumn`, mapped to `MessageStatus` enum)
*   `createdAt` (`IntColumn`)

### 2. Peers Table (`peers.dart`)
*   `peerId` (`TextColumn`, Primary Key)
*   `displayName` (`TextColumn`)
*   `lastKnownEndpointId` (`TextColumn`, nullable)
*   `lastSeen` (`IntColumn`)
*   `createdAt` (`IntColumn`)
*   `updatedAt` (`IntColumn`)

---

## 4. Repository & Messaging Data Flow

```text
NearbyTransport
    ↓
payloadReceivedStream
    ↓
MessagingService (decode payload)
    ↓
MessagingRepository (check messageId uniqueness)
    ├─────────► Already Exists: Ignore
    └─────────► New Payload: Insert to SQLite (status: received)
                     ↓
               Drift Stream (watches conversation)
                     ↓
             MessagingNotifier (updates state)
                     ↓
                ChatPage UI (redraws list)
```

---

## 5. Verification Plan

### Automated Checks
*   Code Generation: `flutter pub run build_runner build --delete-conflicting-outputs`
*   Analysis: `flutter analyze`
*   Tests: `flutter test`
*   APK: `flutter build apk --debug`

### Physical Device Verification
1.  **A sends to B:** Verify text message arrives. Close and reopen Chat screen on both devices and check message history remains intact.
2.  **App Close:** Force terminate VANTRA app on both devices, restart, reconnect, and confirm chat history loads completely.
3.  **Peer Reconnect:** Verify old message threads stay linked to the same peer display name even when the device obtains a new `endpointId` on reconnection.
