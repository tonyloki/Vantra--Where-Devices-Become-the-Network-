# Vantra — Comprehensive Development Roadmap (Phases 16–25)

This document maps out the remaining phases of the Vantra project (Phase 16 through Phase 25). It outlines the architecture, invariants, checkpoints, and verification plans required to implement decentralized multi-hop mesh routing, reliability layers, advanced cryptography, group messaging, and production hardening.

---

## Roadmap Overview

```
                      CURRENT POSITION
                             │
     [Hardening & Optimization Completed — 154 Tests Passing]
                             │
                             ▼
 ┌────────────────────────────────────────────────────────┐
 │            MESH ROUTING & RELIABILITY LAYERS           │
 │  Phase 16: Real Mesh Routing (A → B → C)               │
 │  Phase 17: Mesh Reliability & Failure Recovery         │
 └──────────────────────────┬─────────────────────────────┘
                            │
                            ▼
 ┌────────────────────────────────────────────────────────┐
 │             MEDIA & INTERFACE OPTIMIZATION             │
 │  Phase 18: Large Media Streaming (Direct to Disk)      │
 │  Phase 19: Media Transfer Progress UI                  │
 └──────────────────────────┬─────────────────────────────┘
                            │
                            ▼
 ┌────────────────────────────────────────────────────────┐
 │           SECURITY, IDENTITY & GROUP PROTOCOLS         │
 │  Phase 20: Identity Verification (Safety Numbers / QR) │
 │  Phase 21: Advanced Cryptography (Double Ratchet)      │
 │  Phase 22: Group Messaging Protocol                    │
 └──────────────────────────┬─────────────────────────────┘
                            │
                            ▼
 ┌────────────────────────────────────────────────────────┐
 │           STABILITY, CHAOS & PRODUCTION                │
 │  Phase 23: Android Background & Lifecycle              │
 │  Phase 24: Chaos & Multi-Node Stress Testing           │
 │  Phase 25: Final Production Hardening & Release        │
 └────────────────────────────────────────────────────────┘
```

---

## Phase 16: Real Mesh Routing 🌐

**Goal:** Establish multi-hop messaging where Device A can communicate with Device C via intermediate Device B, without A and C needing direct Nearby Connections linkage.

```
A ─── B ─── C     ==>  A sends to C via B (A has no direct link to C)
```

### 1. Key Invariants
- **No Direct Link Requirement:** A must be able to discover and map a route to C, serialize a packet destined for C, and deliver it to next-hop B without establishing a direct Nearby connection with C.
- **Envelope Wrapping:** The routing header must be unencrypted (readable by relaying nodes), while the message body payload remains encrypted end-to-end between A and C using their derived session keys.
- **Relay Deduplication:** Relaying nodes must discard already-forwarded packet IDs to prevent routing loops.

### 2. Implementation Checklist
- [ ] **Routing Table Schema:** Implement memory and SQLite tables for mapping `destinationPeerId` -> `nextHopEndpointId`, `hopCount`, `ttl` (Time-to-Live), and `lastSeen`.
- [ ] **Route Discovery Protocol:** Implement a flood-based or reactive route request (RREQ) and route reply (RREP) mechanism (such as lightweight AODV).
- [ ] **Relay Layer:** Add forwarding logic in `MessagingService` that intercepts incoming packets not destined for the local `peerId` and routes them to the correct next hop.
- [ ] **Multi-Hop ACKs:** Implement routing-level delivery acknowledgments that propagate backwards from the destination to the source.

---

## Phase 17: Mesh Reliability 🔄

**Goal:** Ensure routing paths recover dynamically when intermediate nodes drop or network topologies shift.

```
  A ─ B ─ C            A ─ B ─ 💀 (B dies)
   \     /      ==>     \     /
    ─ D ─                ─ D ─ C  (Route updates: A → D → C)
```

### 1. Key Invariants
- **Graceful Failover:** If an active relay link drops during transport, the queue must hold the message and initiate route rediscovery.
- **Relay Retries:** Retries must happen per-hop to prevent overloading the network with source-to-destination retransmissions.

### 2. Implementation Checklist
- [ ] **Link Failure Detection:** Detect active endpoint disconnects or timeout signals on intermediate hops.
- [ ] **Route Invalidation (RERR):** Broadcast route error messages to upstream nodes when a next hop becomes unreachable.
- [ ] **Route Rediscovery:** Implement reactive fallback to discover alternative paths (e.g. switching from path `A-B-C` to `A-D-C`).
- [ ] **Hop-Level Retries:** Implement local retry queues per hop before escalating failure back to the sender.

---

## Phase 18: Large Media Streaming 📦

**Goal:** Transition the media transfer protocol to stream bytes directly from/to disk, preventing memory overflow on large transfers up to 500 MB.

### 1. Key Invariants
- **Bounded Memory Footprint:** Memory consumption during sending/receiving must remain constant (e.g. <= 1 MB) regardless of the file size.
- **Immediate Disk Persist:** Received chunks must be written immediately to a temporary file stream on disk instead of accumulating in memory.

### 2. Implementation Checklist
- [ ] **Stream-to-Disk Receiver:** Rewrite `DomainMediaChunk` receiver to pipe incoming bytes directly to `File.openWrite(mode: FileMode.append)`.
- [ ] **Stream-from-Disk Sender:** Refactor the chunking loop to open a read stream from disk and encrypt segments sequentially in a memory-efficient loop.
- [ ] **Pipeline Throttling:** Tune the 5ms delay dynamically based on system load to prevent native thread congestion.

---

## Phase 19: Transfer UX 📊

**Goal:** Connect the back-end transfer state and progress metrics to the UI chat bubbles.

### 1. Key Invariants
- **Accurate Speeds:** Speed and ETA calculation must use a moving window average to avoid spikes.
- **State Consistency:** Pause, Resume, and Cancel buttons on the UI must immediately call back-end media control handlers and update database states.

### 2. Implementation Checklist
- [ ] **Speed & ETA Calculator:** Implement a sliding-window tracker measuring bytes sent over time to compute transfer speed (MB/s) and estimated time of arrival (ETA).
- [ ] **Interactive Media Bubbles:** Add cancel and retry buttons inside `chat_page.dart` media message bubbles.
- [ ] **Progress Updates:** Expose a reactive stream of progress percentages (`0.0` to `1.0`) from `MessagingNotifier` to update UI bubbles dynamically.

---

## Phase 20: Identity Verification 🔐

**Goal:** Implement Safety Number verification using QR code scanning to prevent Man-in-the-Middle (MITM) attacks.

### 1. Key Invariants
- **TOFU Validation:** Out-of-band fingerprint validation must transition a peer's `trustState` from `trusted` (unverified TOFU) to `verified`.
- **Identity Block:** If a verified identity key changes, the app must block all communication and display a red warning dialog.

### 2. Implementation Checklist
- [ ] **Safety Number Generator:** Concatenate local and remote Ed25519 identity keys and format them into readable blocks of numbers (Signal-style).
- [ ] **QR Code Generator & Scanner:** Integrate a QR code renderer and camera scanner to exchange and verify public keys.
- [ ] **Strict Verification State:** Restrict peer connection acceptance logic to reject connections from verified peers whose public keys do not match.

---

## Phase 21: Advanced Cryptography 🛡️

**Goal:** Upgrade the session encryption to use the Signal Double Ratchet protocol for per-message forward secrecy.

### 1. Key Invariants
- **Forward Secrecy:** Compromising a single message key must not expose past ciphertexts.
- **Post-Compromise Security:** Session keys must auto-heal and rotate dynamically as DH exchanges are performed.

### 2. Implementation Checklist
- [ ] **Double Ratchet State Machine:** Implement the Root, Sending, and Receiving KDF chains.
- [ ] **DH Ratchet:** Rotate keys on every roundtrip of communication using ephemeral public keys attached to header envelopes.
- [ ] **Out-Of-Order Handling:** Store skipped message keys in a secure, bounded memory cache for late-arriving packets, deleting them immediately after decryption.

---

## Phase 22: Group Messaging 👥

**Goal:** Build secure, multi-peer group chat rooms across the mesh.

### 1. Key Invariants
- **Consistent Group Membership:** Group membership states must be synchronized across all members.
- **E2E Group Security:** Group messages must be encrypted such that only current authorized members can decrypt them.

### 2. Implementation Checklist
- [ ] **Group Schema:** Create tables for group metadata, active member lists, and cryptographic group keys.
- [ ] **Sender Keys Protocol:** Implement group encryption where each member distributes a signature/encryption key (Sender Key) to other members of the group.
- [ ] **Membership Changes:** Implement protocols to distribute fresh group keys when members are added or removed.

---

## Phase 23: Background & Lifecycle 🔋

**Goal:** Ensure the P2P connection and message delivery process is reliable when Vantra is backgrounded or the screen is locked.

### 1. Key Invariants
- **Battery Optimization:** Limit radio scanning rates when backgrounded to prevent battery drain.
- **State Recovery:** Rebuild databases, secure sessions, and queues seamlessly after system-initiated process termination.

### 2. Implementation Checklist
- [ ] **Android Background Services:** Implement a persistent Android Foreground Service with a notification to prevent process suspension.
- [ ] **Wakelock Integration:** Hold partial CPU wakelocks during active file transmissions.
- [ ] **Background Suspensions:** Halt discovery/advertising during inactive background states, and auto-resume on app focus.

---

## Phase 24: Chaos & Stress Testing 🧪

**Goal:** Execute automated stress, failure, and performance validation to verify system stability.

### 1. Testing Checklist
- [ ] **Disconnect During Handshake:** Interrupt transport during ECDH exchanges and verify keys are cleaned up.
- [ ] **Middle-Node Failure:** Simulate dropping a middle relay node (Device B) during a multi-hop transfer and verify route rediscovery.
- [ ] **Concurrency Stress:** Send 100 concurrent messages and 10 large media transfers simultaneously and verify zero packet duplicates or database corruption.
- [ ] **Orphan File Cleanups:** Verify that aborted transfers leave no temporary files on disk.

---

## Phase 25: Final Production Hardening 🏭

**Goal:** Run final release audits, static analysis, and packaging for the final release candidate.

### 1. Hardening Checklist
- [ ] **Security Review:** Audit ciphers, nonces, key storage, and replay windows.
- [ ] **Memory Profiling:** Inspect Dart heap size during large transfers to ensure no leaks.
- [ ] **Release APK Compilation:** Build the final release bundle (`flutter build apk --release`) and optimize size.
- [ ] **Multi-Device Live Test:** Validate the entire mesh topology using a test group of 4-5 physical devices.
