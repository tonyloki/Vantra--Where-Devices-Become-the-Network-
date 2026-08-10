# VANTRA — Networking Specifications

## Phase Status

*   **Current Phase:** Phase 9
*   **Status:** Production Connection Lifecycle, Global Peer Discovery & App background suspension completed.

## Implemented
- Nearby Connections API integration via `NearbyTransport` (P2P_POINT_TO_POINT strategy).
- Single Global Owner: `NearbyConnectionService` manages advertising, discovery, and connection permissions.
- App Background Suspension: Automatically halts advertising and discovery when backgrounded, resuming them upon foregrounding to save battery.
- Diagnostic Warning Banners: Renders alert states when GPS is disabled or permissions are denied.
- Global Connection Pairing Prompts: Catch incoming/outgoing request states globally and present pairing code sheets.

## Not Implemented Yet
- Mesh routing and multi-hop topologies (Future versions).
- Group communication (Future versions).

## Transport Engine
VANTRA uses Google's Nearby Connections API via the `nearby_connections` package in Flutter.
Communication operates entirely offline without cellular data or Internet connectivity. Device discovery and payload transmission require Wi-Fi and Bluetooth radios to be enabled.
