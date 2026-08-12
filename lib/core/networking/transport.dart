import 'dart:typed_data';

/// Abstract transport boundary. Phase 1 begins here.
/// All communication subsystems depend on this interface, not on any concrete
/// implementation (e.g. NearbyTransport). The application/domain layers must
/// never import from `communication/transport/nearby_transport.dart` directly.
enum ConnectionStatus {
  idle,
  discovering,
  advertising,
  connecting,
  accepting,
  connected,
  disconnected,
  rejected,
  error
}

class DiscoveredPeer {
  final String id;
  final String name;
  final String serviceId;

  const DiscoveredPeer({required this.id, required this.name, required this.serviceId});
}

class ConnectionUpdate {
  final String endpointId;
  final ConnectionStatus status;
  final String endpointName;
  final String? authenticationToken;
  final bool isIncoming;
  final String? errorMessage;

  const ConnectionUpdate({
    required this.endpointId,
    required this.status,
    required this.endpointName,
    this.authenticationToken,
    this.isIncoming = false,
    this.errorMessage,
  });
}

class PayloadReceivedEvent {
  final String endpointId;
  final Uint8List bytes;

  const PayloadReceivedEvent({required this.endpointId, required this.bytes});
}

abstract interface class Transport {
  Future<void> startDiscovery(String localName);
  Future<void> stopDiscovery();

  Future<void> startAdvertising(String localName);
  Future<void> stopAdvertising();

  Future<void> connect(String localName, String endpointId);
  Future<void> acceptConnection(String endpointId);
  Future<void> rejectConnection(String endpointId);
  Future<void> disconnect(String endpointId);

  Future<void> send(String endpointId, Uint8List data);

  Stream<List<DiscoveredPeer>> get discoveredPeersStream;
  Stream<ConnectionUpdate> get connectionUpdateStream;
  Stream<PayloadReceivedEvent> get payloadReceivedStream;
}
