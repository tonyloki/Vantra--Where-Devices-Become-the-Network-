# VANTRA

> Where Devices Become the Network.

VANTRA is a decentralized, offline-first peer-to-peer communication platform designed to allow nearby Android devices to discover each other, establish secure connections, and exchange messages without Internet or cellular networks.

## Phase Status

*   **Current Phase:** Phase 14
*   **Status:** Secure chunked media/file transfer protocol, capabilities-based version negotiation, connection recovery protection, and SQLite reassembly engine completed.

## Completed Core Phases

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

## Architecture Overview

VANTRA features a highly decoupled, layered architecture to isolate presentation widgets, Riverpod state notifiers, domain-level wire formatting (Protobuf), cryptographic security operations, and offline transports:

### Architectural Layer Diagram (Phase 14)

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

### Protocol & Media Transfer Workflow (V2)

The sequential workflow of connection establishment, cryptographic handshake, version range negotiation, capability exchange, and chunked media transfer is illustrated below:

```mermaid
sequenceDiagram
    autonumber
    actor Alice as Device A (Sender)
    actor Bob as Device B (Receiver)

    Note over Alice, Bob: 1. Connection & Version Negotiation
    Alice->>Bob: Connection Request (Nearby P2P)
    Bob-->>Alice: Connection Accepted
    Alice->>Bob: IDENTITY_SECURE (Handshake: version range [1, 2], identity key, ephemeral key, signature)
    Bob->>Alice: IDENTITY_SECURE (Handshake: version range [1, 2], identity key, ephemeral key, signature)
    Note over Alice, Bob: Verify Ed25519 signature & derive session keys via X25519 ECDH + HKDF-SHA256
    Note over Alice, Bob: Negotiated Version calculated: 2 (V2 Mode)

    Note over Alice, Bob: 2. Encrypted V2 Capabilities Exchange
    Alice->>Bob: CapabilitiesExchange (seq 1, encrypted: [text, image, file])
    Bob->>Alice: CapabilitiesExchange (seq 1, encrypted: [text, image, file])
    Note over Alice, Bob: Both calculate intersection: [text, image, file] -> status promoted to CONNECTED

    Note over Alice, Bob: 3. Secure Bidirectional Messaging (Text)
    Alice->>Bob: VantraPlaintext.TextBody (seq 2, encrypted: "Hello!")
    Bob->>Alice: Delivery ACK (seq 2, encrypted status: delivered)

    Note over Alice, Bob: 4. Secure Chunked Media/File Transfer Loop
    Alice->>Bob: MediaControl.OFFER (seq 3, transferId, fileName, fileSize, sha256)
    Note over Bob: Verify capabilities & check local storage limits
    Note over Bob: Scan temp folder for chunk progress (0 chunks found)
    Bob->>Alice: MediaControl.ACCEPT (seq 3, nextExpectedChunk: 0)

    Note over Alice: Read 16 KB chunks from file
    Alice->>Bob: MediaChunk 1/4 (seq 4, raw bytes)
    Alice->>Bob: MediaChunk 2/4 (seq 5, raw bytes)
    Alice->>Bob: MediaChunk 3/4 (seq 6, raw bytes)
    Alice->>Bob: MediaChunk 4/4 (seq 7, raw bytes)
    Note over Bob: Decrypt and write chunks to temp folder

    Note over Bob: Reassemble chunks sequentially
    Note over Bob: Compute SHA-256 of reassembled file & verify match with OFFER hash
    Bob->>Alice: Delivery ACK (seq 4, originalMessageId, status: delivered)
    Note over Alice: Set message status to SENT
```

See the documentation in `docs/` for specific specifications:
*   [Architecture Guide](docs/architecture.md)
*   [Protocol Spec](docs/protocol.md)
*   [Security Architecture](docs/security.md)
*   [Networking Specs](docs/networking.md)
*   [Testing Guidelines](docs/testing.md)
