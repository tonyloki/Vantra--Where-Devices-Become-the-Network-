import 'dart:async';
import 'dart:typed_data';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/security/secure_storage_service.dart';

class FakeTransport implements Transport {
  final _peersController = StreamController<List<DiscoveredPeer>>.broadcast();
  final _connectionController = StreamController<ConnectionUpdate>.broadcast();
  final _payloadController = StreamController<PayloadReceivedEvent>.broadcast();

  final List<Uint8List> sentPayloads = [];
  final List<String> sentTargets = [];
  bool disconnectCalled = false;
  String? disconnectedTarget;
  bool isDiscovering = false;
  bool isAdvertising = false;

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

  int acceptConnectionCount = 0;
  int rejectConnectionCount = 0;
  final List<String> acceptedEndpoints = [];
  final List<String> rejectedEndpoints = [];

  @override
  Future<void> acceptConnection(String endpointId) async {
    acceptConnectionCount++;
    acceptedEndpoints.add(endpointId);
  }

  @override
  Future<void> rejectConnection(String endpointId) async {
    rejectConnectionCount++;
    rejectedEndpoints.add(endpointId);
  }

  int connectCallCount = 0;
  final List<String> connectedEndpoints = [];
  final List<String> connectLocalNames = [];

  @override
  Future<void> connect(String localName, String endpointId) async {
    connectCallCount++;
    connectedEndpoints.add(endpointId);
    connectLocalNames.add(localName);
  }

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
  Future<void> startAdvertising(String localEndpointName) async {
    isAdvertising = true;
  }

  @override
  Future<void> stopAdvertising() async {
    isAdvertising = false;
  }

  @override
  Future<void> startDiscovery(String localName) async {
    isDiscovering = true;
  }

  @override
  Future<void> stopDiscovery() async {
    isDiscovering = false;
  }

  Future<void> stopAllEndpoints() async {}

  void dispose() {
    _peersController.close();
    _connectionController.close();
    _payloadController.close();
  }
}

class FakeSecureStorageService extends SecureStorageService {
  final Map<String, List<int>> _storage = {};

  FakeSecureStorageService();

  @override
  Future<List<int>?> getIdentityPrivateKeySeed() async {
    return _storage['vantra_identity_private_seed'];
  }

  @override
  Future<void> saveIdentityPrivateKeySeed(List<int> seedBytes) async {
    _storage['vantra_identity_private_seed'] = seedBytes;
  }

  @override
  Future<void> clearIdentityKeys() async {
    _storage.clear();
  }
}
