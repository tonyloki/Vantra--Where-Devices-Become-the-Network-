# VANTRA — Architecture Guide

## Phase Status

*   **Current Phase:** Phase 0
*   **Status:** Foundation and project setup.

## Not Implemented Yet
*   Peer discovery
*   Connections
*   Messaging
*   Encryption
*   Database
*   File transfer
*   Groups
*   Mesh routing

## Overview
VANTRA uses a layered architecture to separate business logic from specific transport layers:
1. Presentation Layer (UI Pages and Riverpod providers)
2. Application / Use Case Layer
3. Domain Layer
4. Communication / Infrastructure Layer (DiscoveryManager, ConnectionManager)
5. Transport Abstraction Layer (`Transport` interface)
6. Concrete Transport Implementation (e.g. `NearbyTransport`)
