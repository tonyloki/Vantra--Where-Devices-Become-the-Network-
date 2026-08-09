import 'dart:async';
import 'dart:typed_data';
import 'package:vantra/core/networking/transport.dart';

class FakeTransport implements Transport {
  final _peersController = StreamController<List<DiscoveredPeer>>.broadcast();
  final _connectionController = StreamController<ConnectionUpdate>.broadcast();
  final _payloadController = StreamController<PayloadReceivedEvent>.broadcast();

  final List<Uint8List> sentPayloads = [];
  final List<String> sentTargets = [];
  bool disconnectCalled = false;
  String? disconnectedTarget;

  @override
  Stream<List<DiscoveredPeer>> get discoveredPeersStream => _peersController.stream;

  @override
  Stream<ConnectionUpdate> get connectionUpdateStream => _connectionController.stream;

  @override
  Stream<PayloadReceivedEvent> get payloadReceivedStream => _payloadController.stream;

  void triggerDiscoveredPeers(List<DiscoveredPeer> peers) {
    _peersController.add(peers);
  }

  void triggerConnectionUpdate(ConnectionUpdate update) {
    _connectionController.add(update);
  }

  void triggerIncomingPayload(String endpointId, Uint8List bytes) {
    _payloadController.add(PayloadReceivedEvent(endpointId: endpointId, bytes: bytes));
  }

  @override
  Future<void> acceptConnection(String endpointId) async {}

  @override
  Future<void> rejectConnection(String endpointId) async {}

  @override
  Future<void> connect(String localName, String endpointId) async {}

  @override
  Future<void> disconnect(String endpointId) async {
    disconnectCalled = true;
    disconnectedTarget = endpointId;
  }

  bool throwErrorOnSend = false;

  @override
  Future<void> send(String endpointId, Uint8List data) async {
    if (throwErrorOnSend) {
      throw Exception('Fake send error');
    }
    sentPayloads.add(data);
    sentTargets.add(endpointId);
  }

  @override
  Future<void> startAdvertising(String localName) async {}

  @override
  Future<void> startDiscovery(String localName) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<void> stopDiscovery() async {}
}
