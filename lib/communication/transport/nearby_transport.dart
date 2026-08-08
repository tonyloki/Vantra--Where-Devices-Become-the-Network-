import 'dart:typed_data';
import 'package:vantra/core/networking/transport.dart';

/// Phase 1 implementation target. All methods throw [UnimplementedError].
/// Do NOT call any nearby_connections APIs here during Phase 0.
class NearbyTransport implements Transport {
  @override
  Future<void> startDiscovery() => throw UnimplementedError('Phase 1');

  @override
  Future<void> stopDiscovery() => throw UnimplementedError('Phase 1');

  @override
  Future<void> startAdvertising() => throw UnimplementedError('Phase 1');

  @override
  Future<void> stopAdvertising() => throw UnimplementedError('Phase 1');

  @override
  Future<void> connect(String endpointId) => throw UnimplementedError('Phase 1');

  @override
  Future<void> disconnect(String endpointId) => throw UnimplementedError('Phase 1');

  @override
  Future<void> send(String endpointId, Uint8List data) => throw UnimplementedError('Phase 1');
}
