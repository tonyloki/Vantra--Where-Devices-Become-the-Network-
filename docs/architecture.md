# VANTRA — Architecture Guide

## Phase Status

*   **Current Phase:** Phase 1
*   **Status:** Communication Proof of Concept (POC).

## Implemented
*   Layered architecture separation with `Transport` abstraction in `lib/core/networking/transport.dart`.
*   Concrete `NearbyTransport` implementation in `lib/communication/transport/nearby_transport.dart`.
*   POC User Interface in `lib/features/poc/poc_page.dart` communicating via `transportProvider` to the transport layer.

## Not Implemented Yet
*   Domain-layer use cases (advertising/discovery managers).
*   Cryptographic security (Phase 4).
*   Protocol buffer messaging protocol serialization (Phase 5).
*   SQLite + Drift local persistence (Phase 7).

## Overview
VANTRA uses a layered architecture to separate business logic from specific transport layers:
1. Presentation Layer (UI Pages and Riverpod providers)
2. Application / Use Case Layer (to be added)
3. Domain Layer (to be added)
4. Communication / Infrastructure Layer (stubs)
5. Transport Abstraction Layer (`Transport` interface)
6. Concrete Transport Implementation (e.g. `NearbyTransport` using `nearby_connections`)

