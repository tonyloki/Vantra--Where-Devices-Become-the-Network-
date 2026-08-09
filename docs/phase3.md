# VANTRA Phase 3: Offline-First SQLite Local Messaging Persistence

VANTRA Phase 3 introduces local SQLite persistence. No cloud synchronization is used.

---

## 1. Overview & Core Philosophy

The primary objective of Phase 3 is to make text messaging resilient to application restarts, session terminations, and UI navigation transitions. VANTRA remains a local-only platform:
*   **Zero Internet Dependence:** The local database acts as the single persistent source of truth, resolving history fully off-line.
*   **Peer Decoupling:** Reconnections that rotate Nearby Connections temporary `endpointId` values still load the correct persistent chat history associated with the permanent `peerId` UUID.

---

## 2. SQLite Database & Drift Design

### Tables Specification

#### 1. Messages (`messages.dart`)
Persists historical chats between the local device and remote peers.

| Column | Drift Type | Description |
|---|---|---|
| `localId` | `IntColumn` | Auto-incrementing primary key. Dictates local arrival sequence ordering. |
| `messageId` | `TextColumn` | Unique UUID of the message. Covered by database unique constraint index. |
| `senderId` | `TextColumn` | Persistent peer ID of the sender. |
| `receiverId` | `TextColumn` | Persistent peer ID of the receiver. |
| `messageText` | `TextColumn` | String content (mapped to SQLite column `text` using `named('text')` to prevent Dart reserved keyword conflicts). |
| `timestamp` | `IntColumn` | Clock millisecond epoch from sender device. |
| `type` | `TextColumn` | String type descriptor (`'TEXT'`). |
| `status` | `TextColumn` | String representation of `MessageStatus` enum mapped via a custom `MessageStatusConverter`. |
| `createdAt` | `IntColumn` | Local insertion timestamp. |

#### 2. Peers (`peers.dart`)
Stores known contacts/devices.

| Column | Drift Type | Description |
|---|---|---|
| `peerId` | `TextColumn` | Persistent UUID, acts as the primary key. |
| `displayName` | `TextColumn` | Last known display name. |
| `lastKnownEndpointId` | `TextColumn` | Last resolved Nearby Connection endpointId. |
| `lastSeen` | `IntColumn` | Milliseconds epoch of last connection update. |
| `createdAt` | `IntColumn` | Database insertion time. |
| `updatedAt` | `IntColumn` | Database record update time. |

---

## 3. Message Lifecycle & State Updates

```text
User inputs message
         ↓
State: MessageStatus.pending
         ↓
Database: Writes message row to SQLite
         ↓
Drift Stream: Fires update notification
         ↓
Riverpod conversationStreamProvider: Emits updated list
         ↓
ChatPage UI: Draws bubble with access_time/pending icon instantly
         ↓
Transport.send()
         ├─────────► SUCCESS: updates SQLite status to MessageStatus.sent (renders check icon)
         └─────────► FAILURE: updates SQLite status to MessageStatus.failed (renders warning icon)
```

---

## 4. Duplicate Payload Protection
Since local radio transmissions can experience retries or replayed packets, incoming payloads must be deduplicated:
1.  **Repository Safeguard:** Before writing to the database, `MessagingRepository` queries the database by `messageId`.
2.  **Unique Constraint:** The database enforces a `UNIQUE` constraint index on the `messageId` column.
3.  **Result:** If a packet with an already existing `messageId` arrives, the write is ignored. The database maintains exactly one row, and the UI displays exactly one message bubble.

---

## 5. Testing & Verification

### In-Memory Isolation Strategy
To prevent tests from corrupting or writing to the physical Android SQLite databases, the entire test suite overrides `appDatabaseProvider` to load an isolated in-memory executor:
```dart
testDb = AppDatabase.forTesting(NativeDatabase.memory());
```
Each unit test spins up its own database instance and disposes of it on tearDown.

### Test Coverage Summary
*   **Database Tests (`database_test.dart`):** Tests insertions, retrieval, updates, bilateral conversation filters, chronological sequence sorting, unique duplicate protection, and peer upsert reconnect mappings.
*   **Pipeline Tests (`messaging_persistence_test.dart`):** Asserts unawaited incoming message triggers, outgoing pending-to-sent status, and failed transport states.
*   **Widget Tests (`chat_persistence_widget_test.dart`):** Validates that `ChatPage` renders historical messages, updates reactively on new packet streams, and locks controls when sessions disconnect.
