import 'dart:typed_data';

/// Abstract transport boundary. Phase 1 begins here.
/// All communication subsystems depend on this interface, not on any concrete
/// implementation (e.g. NearbyTransport). The application/domain layers must
/// never import from `communication/transport/nearby_transport.dart` directly.
abstract interface class Transport {
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  Future<void> startAdvertising();
  Future<void> stopAdvertising();
  Future<void> connect(String endpointId);
  Future<void> disconnect(String endpointId);
  Future<void> send(String endpointId, Uint8List data);
}
