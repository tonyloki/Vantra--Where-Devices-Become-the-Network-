# VANTRA — Phase 6: Peer Discovery, Contacts & Trust Management Plan

## Executive Summary

Phase 6 elevates VANTRA into an offline-first peer messenger by introducing a persistent Contacts experience, nearby peer discovery UI, peer profile management, trust/verification workflows, peer blocking, conversation lists with unread badges, and seamless reconnection UX without altering the underlying cryptographic, transport, or Protobuf layers.

---

## 0. Current Codebase Audit

1. **Current GoRouter Routes** (`lib/main.dart`):
   - Defined routes: `/` (Splash), `/onboarding`, `/home`, `/nearby`, `/chat/:peerId`, `/profile`, `/poc`.
   - Needs additions: `/peer/:peerId` (Peer Profile), `/contacts` (Contacts Page), while keeping `/poc` intact for development.
2. **Current HomePage** (`lib/features/home/home_page.dart`):
   - Minimal placeholder. Will be redesigned into a central hub with bottom navigation or tabbed views (Conversations, Nearby, Contacts, Profile).
3. **Current PocPage** (`lib/features/poc/poc_page.dart`):
   - Full diagnostic & manual testing tool for Phases 1–5. Kept untouched.
4. **Current ChatPage** (`lib/features/messaging/chat_page.dart`):
   - Functional reactive chat UI with ChaCha20-Poly1305 + Protobuf wire integration, delivery checkmarks, and bottom sheet security fingerprint.
   - Needs unread message clearing (`markConversationAsRead`), nickname display, trust status header badge, and direct link to Peer Profile.
5. **Current PeerSession model** (`lib/core/models/peer_session.dart`):
   - Contains `peerId`, `displayName`, `endpointId`, `status`, `publicKey`, `fingerprint`, `trustState`, `isSecure`.
6. **Current Peers Drift table** (`lib/core/database/tables/peers.dart`):
   - Contains: `peerId` (PK), `displayName`, `lastKnownEndpointId`, `publicKey`, `fingerprint`, `trustState`, `protocolVersion`, `lastSeen`, `createdAt`, `updatedAt`.
   - Requires: `TextColumn get nickname => text().nullable()();` for local user aliases.
7. **Current PeerDao** (`lib/core/database/daos/peer_dao.dart`):
   - Basic CRUD (`insertOrUpdatePeer`, `getPeer`, `watchPeers`, `listPeers`).
   - Needs extension for searching, watching trusted/unblocked peers, updating nickname, trust state, and lastSeen.
8. **Current MessageDao** (`lib/core/database/daos/message_dao.dart`):
   - Basic message queries and status updating.
   - Requires: `BoolColumn get isRead => boolean().withDefault(const Constant(false))();` on `Messages` table to track read/unread state per message.
   - Needs queries for unread count calculation and marking conversations as read.
9. **Current MessagingRepository** (`lib/core/messaging/messaging_repository.dart`):
   - Direct bridge between database DAOs and business logic.
   - Needs extensions for `watchConversationSummaries`, `markConversationAsRead`, `updatePeerNickname`, `updatePeerTrust`.
10. **Current MessagingNotifier** (`lib/core/messaging/messaging_provider.dart`):
    - Manages state, transport subscriptions, secure identity handshakes, and sending/receiving encrypted envelopes.
    - Needs integration with blocked/distrusted peer enforcement: if peer is `distrusted`, reject handshake / disconnect transport immediately without establishing cryptographic session.
    - Expose `blockPeer`, `unblockPeer`, `updatePeerNickname`, `updatePeerTrust`.
11. **Current LocalIdentityNotifier** (`lib/core/identity/local_identity_provider.dart`):
    - Robust local identity management (Ed25519 keypair in Android Keystore / secure storage, display name in SharedPreferences).
12. **Current PeerTrustState** (`lib/core/models/peer_trust_state.dart`):
    - Enum values: `untrusted`, `trusted`, `distrusted`.
    - Note: `distrusted` represents **blocked**. Reused cleanly.
13. **Current connection state representation**:
    - `ConnectionStatus` (Transport-level) and `SessionStatus` (PeerSession-level).
14. **Current fingerprint verification UI**:
    - Embedded in modal bottom sheet in `ChatPage`. Will be surfaced in `PeerProfilePage` and `FingerprintVerificationDialog`.
15. **Current security session lifecycle**:
    - Generated per-session using X25519 + HKDF-SHA256, destroyed on disconnect/reconnect.
16. **Current unread/message status capabilities**:
    - Status enum: `pending`, `sent`, `delivered`, `received`, `failed`. `isRead` will be tracked in SQLite.

---

## Proposed Changes & Architecture

### 1. Database Schema & Migration (Version 3)

#### [MODIFY] [peers.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/database/tables/peers.dart)
- Add `TextColumn get nickname => text().nullable()();`

#### [MODIFY] [messages.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/database/tables/messages.dart)
- Add `BoolColumn get isRead => boolean().withDefault(const Constant(false))();`

#### [MODIFY] [app_database.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/database/app_database.dart)
- Increment `schemaVersion` to `3`.
- In `migration.onUpgrade`:
  ```dart
  if (from < 3) {
    await m.addColumn(peers, peers.nickname);
    await m.addColumn(messages, messages.isRead);
  }
  ```

---

### 2. Models & DAOs

#### [NEW] [peer_profile.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/models/peer_profile.dart)
- Domain representation combining persistent SQLite peer data (`peerId`, `displayName`, `nickname`, `publicKey`, `fingerprint`, `trustState`, `lastSeen`, `createdAt`) with transient session state (`SessionStatus`, `isOnline`, `isSecure`).
- Helper getter: `effectiveName => nickname?.isNotEmpty == true ? nickname! : displayName`.

#### [NEW] [conversation_summary.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/models/conversation_summary.dart)
- Domain representation for the conversation list:
  - `peerId`, `displayName`, `nickname`, `fingerprint`, `trustState`
  - `lastMessageText`, `lastMessageTimestamp`, `lastMessageStatus`
  - `unreadCount`
  - `isOnline`, `isSecure`

#### [MODIFY] [peer_dao.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/database/daos/peer_dao.dart)
- Add `watchAllPeers()`, `watchTrustedPeers()`, `searchPeers(String query)`.
- Add `updateNickname(String peerId, String? nickname)`.
- Add `updateTrustState(String peerId, PeerTrustState trustState)`.
- Add `updateLastSeen(String peerId, int lastSeen)`.

#### [MODIFY] [message_dao.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/database/daos/message_dao.dart)
- Add `markConversationAsRead(String localPeerId, String remotePeerId)`: updates `isRead = true` for all messages from `senderId == remotePeerId & receiverId == localPeerId`.
- Add `watchUnreadCount(String localPeerId, String remotePeerId)`.
- Add `watchAllConversationSummaries(String localPeerId)`: groups by conversation peer, computes unread count, and retrieves latest message.

---

### 3. Services & Riverpod Providers

#### [NEW] [peer_discovery_service.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/peers/peer_discovery_service.dart)
- Sits on top of `Transport.discoveredPeersStream` and `Transport.connectionUpdateStream`.
- Exposes clean stream of discovered peers with duplicate filtering and resolution against known SQLite peers.
- Discard transient discoveries when discovery stops.

#### [NEW] [peer_provider.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/peers/peer_provider.dart)
- Riverpod providers:
  - `peerListStreamProvider`: streams all known persistent peers from SQLite.
  - `trustedPeersStreamProvider`: streams trusted contacts.
  - `blockedPeersStreamProvider`: streams blocked/distrusted peers.
  - `peerProfileStreamProvider(peerId)`: streams reactive `PeerProfile` for a specific peer.
  - `conversationSummariesStreamProvider`: streams all conversation previews with unread badges.
  - `nearbyDiscoveredPeersProvider`: streams live discovered nearby devices with resolved trust states.

#### [MODIFY] [messaging_repository.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/messaging/messaging_repository.dart)
- Add methods: `markConversationAsRead`, `updatePeerNickname`, `updatePeerTrustState`, `watchConversationSummaries`.

#### [MODIFY] [messaging_provider.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/core/messaging/messaging_provider.dart)
- **BLOCKING SECURITY INVARIANT**:
  - When `IDENTITY_SECURE` is received, verify the Ed25519 signature canonical transcript.
  - Resolve the persistent `peerId` and check the stored `trustState` in SQLite *before* establishing the secure application session.
  - If `trustState == PeerTrustState.distrusted` (blocked):
    - Reject the connection immediately.
    - Do not transition to `SECURE`.
    - Do not derive or store application session keys in `_securitySessions`.
    - Do not accept encrypted application messages.
    - Disconnect the Nearby endpoint via `Transport.disconnect(endpointId)`.
    - Preserve existing conversation history.
    - Log diagnostic reason: `[VANTRA][SECURITY] BLOCKED PEER CONNECTION REJECTED: peerId=${identity.peerId}`.
- In `_handleIncomingEncryptedMessage`:
  - When saving incoming message, set `isRead: false` unless the user is actively viewing that specific conversation.
- Add actions:
  - `blockPeer(String peerId)`: Sets trust state to `distrusted`, terminates active transport connection and removes any active cryptographic session keys.
  - `unblockPeer(String peerId)`: Sets trust state back to `untrusted` (requires re-verification before trust is granted).
  - `updatePeerTrust(String peerId, PeerTrustState state)`.
  - `updatePeerNickname(String peerId, String? nickname)`.

---

### 4. UI Layer

#### [MODIFY] [home_page.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/features/home/home_page.dart)
- Full navigation hub with `NavigationBar` (or tabs):
  1. **Conversations Tab**: Recent chats, unread counter badges, status indicators, quick floating action button to find nearby peers.
  2. **Nearby Tab**: Live Nearby discovery, start/stop scanning, connection controls.
  3. **Contacts Tab**: Known peers, trusted contacts, search filter, nicknames.
  4. **Profile Tab**: Device identity, display name editing, local fingerprint.

#### [NEW] [conversations_page.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/features/messaging/conversations_page.dart)
- Renders list of `ConversationSummary` items.
- Displays peer effective name (nickname/display name), last message preview, human-formatted timestamp, unread badge counter, and online/secure indicator dot.
- Tapping navigates to `/chat/:peerId`.

#### [NEW] [nearby_peers_page.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/features/peers/nearby_peers_page.dart)
- Clean discovery interface with Start/Stop Discovery button, pulsating scanning animation, peer cards (name, trust badge, connection state).
- Tapping a peer initiates connection or opens Peer Profile.
- Never displays raw technical endpoint IDs.

#### [NEW] [contacts_page.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/features/peers/contacts_page.dart)
- Searchable list of all persistent peers in SQLite.
- Filter by All / Trusted / Blocked.
- Tapping navigates to `/peer/:peerId`.

#### [NEW] [peer_profile_page.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/features/peers/peer_profile_page.dart)
- Detailed peer profile view:
  - Avatar, display name, local nickname (with edit dialog).
  - Trust State banner (`Trusted`, `Untrusted`, `Blocked`).
  - Cryptographic Ed25519 Fingerprint display.
  - Last Seen status ("Online", "Recently active", "Last seen <date>").
  - Context-aware action buttons:
    - [ Connect ] / [ Disconnect ]
    - [ Open Chat ]
    - [ Verify Fingerprint ]
    - [ Rename Nickname ]
    - [ Block / Unblock ] (with confirmation dialog)

#### [MODIFY] [chat_page.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/features/messaging/chat_page.dart)
- App bar displays effective nickname, trust badge (green shield for trusted, amber for untrusted), and info button navigating to `/peer/:peerId`.
- Automatically calls `markConversationAsRead(localPeerId, peerId)` when opened or when new incoming messages arrive while chat is active.

#### [MODIFY] [profile_page.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/features/profile/profile_page.dart)
- Displays local peer ID, editable display name, full Ed25519 cryptographic public key, fingerprint with copy button, and link to POC debug screen.

#### [MODIFY] [main.dart](file:///c:/Users/Logesh/Documents/Vantra/lib/main.dart)
- Update GoRouter routes to register `/peer/:peerId`, `/contacts`, `/nearby`, and `/home`.

---

## 5. Verification Plan

### Automated Tests
1. `test/peer_dao_test.dart`:
   - Verify `insertOrUpdatePeer`, `updateNickname`, `updateTrustState`, `watchAllPeers`, `searchPeers`.
2. `test/conversations_test.dart`:
   - Verify unread message count incrementing on receive, clearing with `markConversationAsRead`, and conversation summary ordering.
3. `test/trust_block_test.dart`:
   - Verify blocking peer terminates active session, prevents handshake completion, and rejects incoming payloads.
   - Verify unblocking restores `untrusted` status without auto-trusting.
4. `test/peer_discovery_test.dart`:
   - Verify discovery service maps endpoint IDs, deduplicates, and associates with known peer records after handshake.
5. `test/chat_widget_test.dart` & `test/security_persistence_test.dart`:
   - Ensure all existing 42 tests continue passing 100%.

### Verification Commands
- `flutter pub run build_runner build --delete-conflicting-outputs`
- `flutter analyze`
- `flutter test`
- `flutter build apk --debug`
