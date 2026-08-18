# VANTRA — Networking Specifications

## Phase Status

*   **Current Phase:** Phase 18: Large Media Streaming (Direct to Disk)
*   **Status:** Multi-hop mesh routing, link-failure recovery (RERR), and direct-to-disk random-access media streaming completed.

---

## Implemented
- **Nearby Connections API:** Integration via `NearbyTransport` utilizing `P2P_CLUSTER` strategy.
- **Single Global Owner:** `NearbyConnectionService` manages advertising, discovery, and connection permissions.
- **App Background Suspension:** Automatically halts advertising and discovery when backgrounded, resuming them upon foregrounding to save battery.
- **Diagnostic Warning Banners:** Renders alert states when Location services are disabled or permissions are denied.
- **Global Connection Pairing Prompts:** Catch incoming/outgoing request states globally and present pairing code sheets.
- **Multi-Hop Mesh Routing:** Establishing dynamic routing paths (e.g. A -> B -> C) using reactive route discovery (RREQ/RREP) without requiring direct Nearby Connection pairing between endpoints.
- **Mesh Reliability:** Link failure detection, Route Error (RERR) propagation, next-hop-aware route invalidation, and hop-level retries.
- **Large Media Direct-to-Disk Streaming:** Sequence validation updates using sliding window replay protection for out-of-order chunk handling, sequential sender-side reading, and direct receiver-side random-access disk writing.

## Not Implemented Yet
- Group communication (Planned for Phase 22).

## Transport Engine
VANTRA uses Google's Nearby Connections API via the `nearby_connections` package in Flutter.
Communication operates entirely offline without cellular data or Internet connectivity. Device discovery and payload transmission require Wi-Fi and Bluetooth radios to be enabled.
