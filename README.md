# VANTRA

> Where Devices Become the Network.

VANTRA is a decentralized, offline-first peer-to-peer communication platform designed to allow nearby Android devices to discover each other, establish secure connections, and exchange messages without Internet or cellular networks.

## Phase Status

*   **Current Phase:** Phase 10
*   **Status:** Persistent trusted peer auto-reconnection, background auto-accept/auto-connect, and cryptographic validation completed.

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

## Architecture Overview

See the documentation in `docs/` for specific specifications:
*   [Architecture Guide](docs/architecture.md)
*   [Protocol Spec](docs/protocol.md)
*   [Security Architecture](docs/security.md)
*   [Networking Specs](docs/networking.md)
*   [Testing Guidelines](docs/testing.md)
