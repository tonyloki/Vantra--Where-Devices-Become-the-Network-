# VANTRA — Phase 8: Production Connection Lifecycle, Global Peer Discovery & App Entry Experience Implementation Plan

This plan documents the audit, root-cause diagnostics, and proposed architecture to transition Vantra from a developer-controlled transport lifecycle to an automated, application-managed connection lifecycle. It also designs a polished animated entry experience using the existing branding asset.

---

## 1. Current Architecture Audit & Findings

After a complete audit of the Phase 1–7 codebase, here are the architectural findings:

1. **Nearby Connections Initialization**: Instantiated inside `NearbyTransport` via `final NearbyConnections _nearby = NearbyConnections()`. `NearbyTransport` is instantiated when the Riverpod `transportProvider` is read or watched.
2. **Advertising Initiation**: Currently initiated only inside `PocPage._startAdvertising()`, calling `ref.read(transportProvider).startAdvertising(...)`. It does not start automatically anywhere in the main application flow.
3. **Discovery Initiation**: Initiated manually in `PocPage._startDiscovery()` and automatically inside `NearbyPeersPage.initState()` via `ref.read(peerDiscoveryServiceProvider).startDiscovery()`.
4. **Discovery Cessation**: Stopped manually in `PocPage` and `NearbyPeersPage` (scanning toggle), and automatically inside `NearbyTransport.connect` immediately before executing the native connection request.
5. **Connection Request Reception**: Received natively by `NearbyConnections.onConnectionInitiated` registered in `startAdvertising` and `requestConnection`. Events are emitted as `ConnectionUpdate` instances on `_connectionUpdateController`.
6. **Accept / Reject Handling**: Executed in `PocPage` dialogs and the root `GlobalConnectionListener` wrapper in `main.dart` which calls `acceptConnection` or `rejectConnection` on `ref.read(transportProvider)`.
7. **Connection Status Callbacks**: Registered natively via `NearbyConnections.requestConnection` and `NearbyConnections.startAdvertising` callbacks.
8. **Payload Callbacks**: Registered natively with `NearbyConnections.acceptConnection` as `onPayLoadRecieved`.
9. **Transport Instantiation**: Declared inside `transportProvider` in `lib/core/networking/transport_provider.dart`.
10. **Transport Scope**: Provider-scoped. It acts as a keep-alive global singleton since `transportProvider` is a standard Riverpod `Provider` (not `autoDispose`).
11. **Provider owning Transport**: `transportProvider`.
12. **Provider owning MessagingService**: `messagingServiceProvider`.
13. **Provider owning MessagingNotifier**: `messagingStateProvider` (managing `MessagingState`).
14. **GlobalConnectionListener Interactions**: Watches `messagingStateProvider`'s `state.activeConnectionRequest`. If non-null, it displays a modal prompt overlay across the entire child tree, intercepting acceptance actions.
15. **POC Discovery/Advertising**: Directly reads `transportProvider` and calls `startDiscovery()` / `startAdvertising()`.
16. **POC Lifecycle Ownership**: Yes. Currently, the developer POC page is the sole place where advertising is configured/started, and the only place that requests permissions on startup.
17. **Removing POC from Path Impact**: It will not break core messaging mechanics, but without it, the app will never start advertising or request permissions on boot.
18. **Riverpod Provider Initialization**: Initialized lazily on first read/watch by mounting widgets.
19. **HomePage Initialization**: Mounts `ConversationsPage`, `NearbyPeersPage`, `ContactsPage`, and `ProfilePage` inside an `IndexedStack`. This triggers `initState` on `NearbyPeersPage` (initiating discovery).
20. **Whether Discovery/Advertising Can Safely Start Before HomePage is Rendered**: Yes, but only *after* the necessary permissions (nearby Wifi, Bluetooth, location) are granted by the user.
21. **App Backgrounded**: Active connections may persist depending on Android OS background limits. Unmanaged scanning/advertising consumes excessive battery.
22. **App Foregrounded**: Re-evaluates permissions and starts/resumes Nearby scanning/advertising.
23. **App Process Restart**: Session keys and native sockets are destroyed. Persistent database queues (Phase 7) survive and wait for re-negotiation.
24. **Peer Disconnect**: Triggers `onDisconnected`. Local session keys are destroyed, and `activeEndpointId` in state is set to null.
25. **New Endpoint Reconnection**: Handshake validates the long-term Ed25519 key, maps the new `endpointId` to the existing `peerId`, derives new session keys, and flushes the outgoing queue.
26. **Discovery Deduplication**: Handled in `PeerDiscoveryService._discoveredMap` using `endpointId` as a unique map key.
27. **Simultaneous Connection Attempts**: The UI disables the Connect button and displays a progress indicator when a connection is pending. There is no multi-peer capability to connect to multiple endpoints at once.
28. **Accidental Duplicate Starts**: Prevented in `PeerDiscoveryService` via `_isDiscovering` state checks.

---

## 2. Root Cause of Transport POC Dependency

The normal Vantra application cannot establish automatic connections without opening the POC page because:
1. **Lazy Provider Instantiation**: The `transportProvider` and `messagingStateProvider` are lazy. If the user does not open pages watching them, they are never initialized.
2. **Missing Automated Lifecycle Control**: Advertising is never started in the main application flow. Discovery is only started if the user navigates to the `NearbyPeersPage` tab, leaving the app completely silent on startup.
3. **No Automatic Permissions Handling**: Permissions and GPS services are only checked and requested inside the POC page.
4. **No App Lifecycle Hooks**: The app does not handle background/foreground transitions, which leads to battery drain or stalled states when resumed.

---

## 3. Proposed Phase 8 Architecture

We will implement a global `NearbyConnectionService` to manage the lifecycle of Nearby Connections. The Transport POC will remain available as an optional debug utility but will be decoupled from the core application lifecycle.

```text
App Launch
    ↓
SplashPage (Plays Logo Animation & Triggers Initialization)
    ↓
NearbyConnectionService.initialize()
    ├── Request Permissions (VantraPermissions)
    ├── Check GPS / Bluetooth status
    └── If Ready → Start Advertising & Discovery
    ↓
Navigation
    ├── First Run → /onboarding
    └── Normal Run → /home (Conversations, Nearby list, etc.)
    ↓
Background Daemon (Listens to system lifecycle, pauses on background, resumes on foreground)
```

---

## 4. Global Connection Service

We will create a keep-alive `NearbyConnectionService` inside `lib/core/networking/nearby_connection_service.dart`.

### Service States
- `initializing`: Requesting permissions or checking service statuses.
- `permissionsRequired`: Permissions are denied; requires user action.
- `locationDisabled`: GPS service is turned off.
- `ready`: Advertising and discovery are active.
- `error`: Native Nearby Connections error or Bluetooth failure.

### Responsibilities
- Coordinates permissions using `VantraPermissions`.
- Automatically retrieves the local device name from `localIdentityStateProvider`.
- Exposes states through Riverpod (`nearbyConnectionServiceProvider`).
- **Lifecycle Ownership**: `NearbyConnectionService` owns the production Nearby lifecycle (not the UI / SplashPage). It controls automatic start, stop, pause on background, and resume on foreground.
- Implements `WidgetsBindingObserver` to pause discovery/advertising when the app is backgrounded, and automatically resume them on foregrounding.

---

## 5. Application Startup & Navigation Flow

1. **Splash Page**: Configured as GoRouter's initial location (`/`). It triggers `ref.read(nearbyConnectionServiceProvider.notifier).initialize()`.
2. **Onboarding Check**: Persist an `onboarding_completed` boolean in `SharedPreferences` to ensure the onboarding screen is shown once on first launch, then bypassed.
3. **Animation Non-Blocking Rule**:
   - The logo animation plays for exactly 1.5 seconds.
   - If initialization succeeds before 1.5s, the app waits for the animation to finish, then routes to `/home` (or `/onboarding`).
   - If initialization is still in progress after 2.0s, the app routes to `/home` anyway and lets the service complete initialization in the background.
   - If initialization fails (e.g. permissions denied), the Splash page pauses and displays a clear error state with a retry action button.

---

## 6. Logo & Entry Animation Design

We will use the existing logo asset located at `lib/Assets/Logo.png` without copying or modifying it. We will declare it in `pubspec.yaml` as `lib/Assets/Logo.png`.

### Animation Sequence
- **Background**: Deep black/slate background (`Color(0xFF0F0E13)`).
- **Logo Transition**: The logo scales smoothly from `0.8` to `1.0` and fades from `0.0` to `1.0` opacity over 1.2 seconds using `Curves.easeOutQuart`.
- **Text Transition**: The branding title "VANTRA" (monospaced, letter-spaced) and tagline "Where Devices Become the Network" fade in below the logo over 400ms.
- **Total Duration**: ~1.6 seconds.

---

## 7. File-by-File Modifications

### NEW FILES
1. **`lib/core/networking/nearby_connection_service.dart`**
   - **Responsibility**: Manages the global Nearby Connections lifecycle, permissions, service checks, and app lifecycle state.
   - **Test Coverage**: Unit tests verifying transition states (`initializing` → `ready`, `permissionsRequired`, etc.).

### MODIFIED FILES
1. **`pubspec.yaml`**
   - **Proposed Change**: Declare `lib/Assets/Logo.png` in the assets section.
   - **Why Necessary**: Enables the Flutter framework to load the logo image asset.
2. **`lib/main.dart`**
   - **Proposed Change**:
     - Remove the dummy `SplashPage` and implement a state-aware animated `SplashPage`.
     - Register `builder` in `MaterialApp.router` to continue rendering `GlobalConnectionListener`.
     - Modify routing configuration to handle startup logic.
3. **`lib/features/onboarding/onboarding_page.dart`**
   - **Proposed Change**: Write `onboarding_completed: true` to `SharedPreferences` when "Continue" is pressed.
4. **`lib/features/poc/poc_page.dart`**
   - **Proposed Change**: Decouple lifecycle triggers; bind status displays to `nearbyConnectionServiceProvider`.
5. **`lib/features/peers/nearby_peers_page.dart`**
   - **Proposed Change**: Display connection lifecycle errors (permissions/GPS) if present in `NearbyConnectionState`.
6. **`lib/core/peers/peer_discovery_service.dart`**
   - **Proposed Change**: Remove local tab-based start/stop discovery logic; align with the global service state.

---

## 8. Database Impact
No database schema changes are required. The current schemas (Peers v3, Messages v4) remain fully compatible.

---

## 9. Security Impact & Invariants

Phase 8 preserves all existing security invariants:
1. **Ed25519 Authentication**: Signatures are verified before transition to `isSecure`.
2. **X25519 Ephemeral Key Exchange**: Handshake generates new ephemeral keys for every connection.
3. **HKDF Key Derivation**: Session keys are derived using ephemeral secrets.
4. **ChaCha20-Poly1305 Encryption**: All application messages are encrypted.
5. **AAD/messageId Binding**: Nonces are bound to message IDs.
6. **Session ID Validation**: Session IDs must match active security session records.
7. **Sequence Validation**: Sequence numbers are strictly matched.
8. **Replay Protection**: Prevents duplicate sequence packet delivery.
9. **Encrypted ACK Requirement**: ACKs are encrypted inside `VantraPlaintext`.
10. **Distrusted-Peer Rejection**: Connections from distrusted peers are dropped immediately upon receiving `IDENTITY_SECURE`.
11. **Fingerprint Trust Model**: Untrusted fingerprint UI is displayed for manual key verification.
12. **Secure Session Key Destruction on Disconnect**: Keys are destroyed immediately when a disconnect event is processed.

---

## 10. Verification Checklist

- [x] Architecture audit completed
- [x] Root cause identified
- [x] Single global Transport instance
- [x] App startup initializes transport
- [x] Advertising starts automatically
- [x] Discovery starts automatically
- [x] Global connection request overlay
- [x] Secure handshake preserved
- [x] Trust/blocking preserved
- [x] Reconnection preserved
- [x] Phase 7 queue preserved
- [x] Chat preserved
- [x] Transport POC no longer required
- [x] Existing assets/logo.png verified and used
- [x] VANTRA entry animation implemented
- [x] Entry animation does not block indefinitely
- [x] Initialization errors handled gracefully
- [x] flutter analyze passes
- [x] flutter test passes
- [x] APK builds
- [ ] Physical Device A ↔ B test passes
- [ ] Offline/no-internet test passes
