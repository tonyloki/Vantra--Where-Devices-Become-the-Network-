# VANTRA — Testing Guidelines

## Phase Status

*   **Current Phase:** Phase 1
*   **Status:** Communication Proof of Concept (POC).

## Implemented
*   Automated unit tests for Vantra Transport domain models and serialization validation (`test/transport_test.dart`).
*   Verification suite guidelines for two physical devices connection status, payload transmissions, and disconnect recovery.

## Phase 1 Verification Guidelines
1. Ensure both devices have Cellular data turned OFF and Wi-Fi Internet disconnected.
2. Device A starts Advertising with name "Vantra-A".
3. Device B starts Discovering with name "Vantra-B".
4. Confirm Device B detects Device A.
5. Initiate Connection from B.
6. Verify Connection Request popup appears on A with matching auth token. Click Accept.
7. Verify Connection Status transitions to Connected on both screens.
8. Send UTF-8 text from A to B and vice versa. Confirm reception.
9. Disconnect and ensure clean idle state reset on both.

