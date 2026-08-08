# VANTRA — Networking Specifications

## Phase Status

*   **Current Phase:** Phase 1
*   **Status:** Communication Proof of Concept (POC).

## Implemented
*   Nearby Connections API integration via `NearbyTransport`.
*   Version-aware permission checking (API 24-36).
*   Local GPS/Location service verification status.
*   One-to-one P2P connection advertising and discovery.
*   Direct payload byte transmission (UTF-8 strings).

## Not Implemented Yet
*   Session recovery and reliability queues (Phase 8).
*   Mesh routing and multi-hop topologies (Future versions).
*   Group communication (Future versions).

## Transport Engine
VANTRA uses Google's Nearby Connections API via the `nearby_connections` package in Flutter.
The connection strategy is strictly `P2P_POINT_TO_POINT` for direct, high-bandwidth one-to-one offline communication.
Communication operates entirely without cellular data or Internet connectivity.
Device discovery and payload transmission require Wi-Fi and Bluetooth radios to be enabled.
