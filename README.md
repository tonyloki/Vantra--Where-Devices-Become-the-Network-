# VANTRA

> Where Devices Become the Network.

![Vantra Logo](lib/Assets/Logo.png)

VANTRA is a decentralized, offline-first peer-to-peer (P2P) communication platform designed to allow nearby Android devices to discover each other, establish secure connections, and exchange messages and large media files without Internet or cellular networks.

---

## Why It Matters

In a world dependent on centralized internet service providers and cellular towers, communication is vulnerable to surveillance, outages, natural disasters, and censorship. VANTRA is designed to solve these issues:
- **Resilience:** Operates during grid failures, natural disasters, or in remote offline areas.
- **Privacy:** Eliminates central servers, metadata tracking, and third-party intermediaries.
- **Zero Cost:** Uses point-to-point Wi-Fi Direct and Bluetooth radios to transmit data locally at no cellular cost.

---

## Solution

VANTRA implements a robust multi-hop mesh network:
- **Zero-Config Discovery:** Nearby devices automatically find each other and establish local connection topologies.
- **End-to-End Cryptography:** Handshakes verify identity and establish session keys, ensuring confidentiality, integrity, and forward secrecy.
- **Multi-Hop Mesh Routing:** Packets are automatically relayed via intermediate nodes, allowing end-to-end delivery between devices out of physical radio range.
- **Direct-to-Disk Media Streaming:** Supports transferring large files (up to 500 MB) with a bounded memory footprint.

---

## Tech Stack

| Layer | Technology | Description |
|---|---|---|
| **Framework** | Flutter & Dart | Cross-platform runtime and UI shell |
| **State Management** | Riverpod | Reactive state management and dependency injection |
| **Local Database** | Drift (SQLite) | Persistent schema-safe offline storage |
| **Transport Protocol** | Google Nearby Connections | Bluetooth and Wi-Fi Direct point-to-point radios |
| **Serialization** | Protocol Buffers (Protobuf) | Compact binary wire framing and serialization |
| **Identity & Exchange** | Ed25519 & X25519 | Cryptographic identities and ephemeral key exchange |
| **Cipher AEAD** | ChaCha20-Poly1305 | Authenticated encryption with Associated Data (AAD) binding |

---

## Architecture

VANTRA features a highly decoupled, layered architecture to isolate presentation, application state, domain protocols, cryptographic security, and transport layers:

```mermaid
graph TD
    classDef pres fill:#5C6BC0,stroke:#3F51B5,stroke-width:2px,color:#fff;
    classDef app fill:#7E57C2,stroke:#5E35B1,stroke-width:2px,color:#fff;
    classDef domain fill:#AB47BC,stroke:#8E24AA,stroke-width:2px,color:#fff;
    classDef crypto fill:#26A69A,stroke:#00897B,stroke-width:2px,color:#fff;
    classDef transport fill:#FFA726,stroke:#FB8C00,stroke-width:2px,color:#fff;
    classDef db fill:#EC407A,stroke:#D81B60,stroke-width:2px,color:#fff;

    subgraph Presentation ["Presentation Layer"]
        UI["ChatPage / ConversationsPage<br/>ContactsPage / SplashPage"]:::pres
    end

    subgraph State ["Application State Layer"]
        Riverpod["MessagingNotifier<br/>(Riverpod Providers)"]:::app
    end

    subgraph Domain ["Domain & Wire Format Layer"]
        Service["MessagingService / LocalIdentity"]:::domain
        Codec["ProtobufCodec<br/>(VantraWireEnvelope v1/v2)"]:::domain
        NearbySvc["NearbyConnectionService"]:::domain
    end

    subgraph Crypto ["Cryptographic Security Layer"]
        CryptoSvc["CryptoService (X25519 DH, Ed25519 Sign)"]:::crypto
        Cipher["ChaCha20-Poly1305 AEAD<br/>(Monotonic counters & Salt nonces)"]:::crypto
        Session["SecuritySession<br/>(In-Memory Keys & Sequences)"]:::crypto
    end

    subgraph Storage ["Local Persistence Data Layer"]
        Repo["MessagingRepository"]:::db
        Drift["Drift ORM / SQLite<br/>(transferId, sha256, filePath)"]:::db
    end

    subgraph Transport ["Transport Layer"]
        NetTransport["NearbyTransport"]:::transport
        NearbyAPI["Nearby Connections API<br/>(P2P point-to-point radios)"]:::transport
    end

    UI --> Riverpod
    Riverpod --> Service
    Riverpod --> Repo
    Service --> Codec
    Codec --> CryptoSvc
    CryptoSvc --> Cipher
    Cipher --> Session
    Cipher --> NetTransport
    Repo --> Drift
    NetTransport --> NearbyAPI
```

---

## Flowchart: Connection & Secure Session Handshake

```mermaid
graph TD
    Start([Discovered Endpoint]) --> RoleNegotiate{Compare localPeerId vs remotePeerId}
    RoleNegotiate -->|local < remote| Initiator[Send Connection Request]
    RoleNegotiate -->|local >= remote| Responder[Wait for Connection Request]
    
    Initiator --> ConnectSuccess{Connection Established?}
    Responder --> ConnectSuccess
    
    ConnectSuccess -->|Yes| SecureHandshake[Exchange IDENTITY_SECURE<br/>Min/Max supported version & Ephemeral X25519]
    ConnectSuccess -->|No| Disconnect([Disconnect])
    
    SecureHandshake --> SigVerify{Verify Ed25519 signature}
    SigVerify -->|Match| KeyDerivation[Derive session keys via X25519 ECDH + HKDF-SHA256]
    SigVerify -->|Mismatch| Warning[Show Mismatch Alert & Disconnect]
    
    KeyDerivation --> VersionNegotiate{Negotiated Version?}
    VersionNegotiate -->|V2| CapExchange[Send Encrypted CapabilitiesExchange]
    VersionNegotiate -->|V1| Connected[Status: Connected<br/>Capabilities default to text]
    
    CapExchange --> CapMatch{Intersects capabilities?}
    CapMatch -->|Yes| Connected
    CapMatch -->|No| Disconnect
```

---

## Workflow: E2E Mesh Relaying & Large Media Streaming

### Mesh Message Relaying (A -> B -> C)
```mermaid
sequenceDiagram
    autonumber
    actor Alice as Device A (Sender)
    actor Bob as Device B (Relay)
    actor Charlie as Device C (Receiver)

    Note over Alice, Charlie: Alice establishes secure session with Charlie E2E. Bob only relays.
    Alice->>Bob: Envelope: destination=Charlie, nextHop=Bob (Encrypted payload inside)
    Note over Bob: Parse routing header. ID not mine -> lookup next hop to Charlie
    Bob->>Charlie: Envelope: destination=Charlie, nextHop=Charlie (Encrypted payload inside)
    Note over Charlie: Parse routing header. ID is mine -> Decrypt E2E payload
    Charlie->>Bob: Routing ACK (Backwards propagation)
    Bob->>Alice: Routing ACK
```

### Direct-to-Disk Media Streaming (V2)
```mermaid
sequenceDiagram
    autonumber
    actor Alice as Device A (Sender)
    actor Bob as Device B (Receiver)

    Note over Alice, Bob: Direct-to-disk large media transfer loop
    Alice->>Bob: MediaControl.OFFER (transferId, size, sha256)
    Note over Bob: Check capabilities & space limits
    Bob->>Alice: MediaControl.ACCEPT (nextExpectedChunk: 0)
    
    Note over Alice: Open file as RandomAccessFile
    Alice->>Bob: MediaChunk 0/N (Encrypted segment)
    Note over Bob: Seek & write directly to offset
    Alice->>Bob: MediaChunk 1/N (Encrypted segment)
    Note over Bob: Seek & write directly to offset
    
    Note over Alice: Close RandomAccessFile
    Note over Bob: Close .tmp file & Verify SHA-256 hash
    Note over Bob: Hash Match -> Atomically rename to target folder
    Bob->>Alice: Delivery ACK (originalMessageId, status: delivered)
```

---

## Phase Status

*   **Current Phase:** Phase 19: Media Transfer Progress UI
*   **Completed Phases:**
    *   **Phase 0:** Scaffold Foundation & Project Setup
    *   **Phase 1:** Direct P2P Connectivity & Raw Byte Transfer (Nearby Connections)
    *   **Phase 2:** Persistent Peer Identity & Text Messaging Core
    *   **Phase 3:** Offline-First SQLite Local Messaging Persistence (Drift SQLite)
    *   **Phase 4:** Secure Handshake, Ephemeral Key Exchange (X25519) & Cryptographic Signature Verification (Ed25519)
    *   **Phase 5:** Protobuf Wire Serialization & Encrypted ACK Protocol
    *   **Phase 6:** Peer Discovery, Contacts Book, Trust Management & Peer Blocking
    *   **Phase 7:** Persistent Outgoing Queue, Duplicate-Message ACK Recovery, and Crash Resiliency
    *   **Phase 8:** Production Connection Lifecycle & App Entry Experience
    *   **Phase 9:** Production UI/UX Polish & Dedicated Android Launcher Icons
    *   **Phase 10:** Persistent Trusted Peer Auto-Reconnection & Cryptographic Mismatch Warnings
    *   **Phase 11:** Protocol V2 Version Negotiation & Async Capability-Based Exchange
    *   **Phase 12:** Vantra V2 Core Image/File Transfer Protocol (OFFER/ACCEPT control messages)
    *   **Phase 13:** Generalized File Transfer Engine, SQLite Schema Migration, & SHA-256 Hash Verification
    *   **Phase 14:** Capability-Based Connection Recovery Protection & Physical Device Stabilization
    *   **Phase 15:** Memory-Bounded File Chunking & Performance Optimization
    *   **Phase 16:** Real Mesh Routing (A -> B -> C) & Route Table Schema
    *   **Phase 17:** Mesh Reliability, RERR Route Invalidation & Hop-Level Retries
    *   **Phase 18:** Large Media Streaming (Direct to Disk), sliding window validation, & fallback chunk sizing
