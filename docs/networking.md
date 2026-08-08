# VANTRA — Networking Specifications

## Phase Status

*   **Current Phase:** Phase 0
*   **Status:** Foundation and project setup.

## Not Implemented Yet
*   Nearby Connections API integration
*   Peer advertising / discovery execution
*   Payload exchange and session recovery

## Transport Engine
VANTRA uses Google's Nearby Connections API via the `nearby_connections` package in Flutter.
The connection strategy is P2P_POINT_TO_POINT for reliable one-to-one offline communication.
