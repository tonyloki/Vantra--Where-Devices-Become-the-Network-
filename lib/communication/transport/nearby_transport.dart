import 'dart:async';
import 'dart:typed_data';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/utils/logger.dart';
import 'package:vantra/core/errors/vantra_exceptions.dart';

class NearbyTransport implements Transport {
  final _nearby = Nearby();
  final _strategy = Strategy.P2P_POINT_TO_POINT;
  static const _serviceId = 'me.vantra.vantra';

  final _discoveredPeersController = StreamController<List<DiscoveredPeer>>.broadcast();
  final _connectionUpdateController = StreamController<ConnectionUpdate>.broadcast();
  final _payloadReceivedController = StreamController<PayloadReceivedEvent>.broadcast();

  final List<DiscoveredPeer> _discoveredPeers = [];

  @override
  Stream<List<DiscoveredPeer>> get discoveredPeersStream => _discoveredPeersController.stream;

  @override
  Stream<ConnectionUpdate> get connectionUpdateStream => _connectionUpdateController.stream;

  @override
  Stream<PayloadReceivedEvent> get payloadReceivedStream => _payloadReceivedController.stream;

  @override
  Future<void> startAdvertising(String localName) async {
    VantraLogger.log('NearbyTransport: startAdvertising for $localName');
    final result = await _nearby.startAdvertising(
      localName,
      _strategy,
      serviceId: _serviceId,
      onConnectionInitiated: (id, info) {
        VantraLogger.log('NearbyTransport: Connection initiated by $id (${info.endpointName})');
        _connectionUpdateController.add(ConnectionUpdate(
          endpointId: id,
          status: ConnectionStatus.connecting,
          endpointName: info.endpointName,
          authenticationToken: info.authenticationToken,
          isIncoming: info.isIncomingConnection,
        ));
      },
      onConnectionResult: (id, status) {
        VantraLogger.log('NearbyTransport: Connection result for $id: $status');
        if (status == Status.CONNECTED) {
          _connectionUpdateController.add(ConnectionUpdate(
            endpointId: id,
            status: ConnectionStatus.connected,
            endpointName: id,
          ));
        } else if (status == Status.REJECTED) {
          _connectionUpdateController.add(ConnectionUpdate(
            endpointId: id,
            status: ConnectionStatus.rejected,
            endpointName: id,
          ));
        } else {
          _connectionUpdateController.add(ConnectionUpdate(
            endpointId: id,
            status: ConnectionStatus.error,
            endpointName: id,
            errorMessage: 'Connection failed with status: $status',
          ));
        }
      },
      onDisconnected: (id) {
        VantraLogger.log('NearbyTransport: Disconnected from $id');
        _connectionUpdateController.add(ConnectionUpdate(
          endpointId: id,
          status: ConnectionStatus.disconnected,
          endpointName: id,
        ));
      },
    );

    if (!result) {
      throw const VantraException('Failed to start advertising');
    }
  }

  @override
  Future<void> stopAdvertising() async {
    VantraLogger.log('NearbyTransport: stopAdvertising');
    await _nearby.stopAdvertising();
  }

  @override
  Future<void> startDiscovery(String localName) async {
    VantraLogger.log('NearbyTransport: startDiscovery for $localName');
    _discoveredPeers.clear();
    _discoveredPeersController.add(List.unmodifiable(_discoveredPeers));

    final result = await _nearby.startDiscovery(
      localName,
      _strategy,
      serviceId: _serviceId,
      onEndpointFound: (id, name, serviceId) {
        VantraLogger.log('NearbyTransport: Endpoint found $id ($name)');
        if (!_discoveredPeers.any((p) => p.id == id)) {
          _discoveredPeers.add(DiscoveredPeer(id: id, name: name, serviceId: serviceId));
          _discoveredPeersController.add(List.unmodifiable(_discoveredPeers));
        }
      },
      onEndpointLost: (id) {
        VantraLogger.log('NearbyTransport: Endpoint lost $id');
        if (id != null) {
          _discoveredPeers.removeWhere((p) => p.id == id);
          _discoveredPeersController.add(List.unmodifiable(_discoveredPeers));
        }
      },
    );

    if (!result) {
      throw const VantraException('Failed to start discovery');
    }
  }

  @override
  Future<void> stopDiscovery() async {
    VantraLogger.log('NearbyTransport: stopDiscovery');
    await _nearby.stopDiscovery();
    _discoveredPeers.clear();
    _discoveredPeersController.add(List.unmodifiable(_discoveredPeers));
  }

  @override
  Future<void> connect(String localName, String endpointId) async {
    VantraLogger.log('NearbyTransport: connect to $endpointId');
    try {
      await stopDiscovery();
    } catch (e) {
      VantraLogger.log('NearbyTransport: failed to stop discovery before connect: $e');
    }
    final result = await _nearby.requestConnection(
      localName,
      endpointId,
      onConnectionInitiated: (id, info) {
        VantraLogger.log('NearbyTransport: Connection initiated with $id (${info.endpointName})');
        _connectionUpdateController.add(ConnectionUpdate(
          endpointId: id,
          status: ConnectionStatus.connecting,
          endpointName: info.endpointName,
          authenticationToken: info.authenticationToken,
          isIncoming: info.isIncomingConnection,
        ));
      },
      onConnectionResult: (id, status) {
        VantraLogger.log('NearbyTransport: Connection result for $id: $status');
        if (status == Status.CONNECTED) {
          _connectionUpdateController.add(ConnectionUpdate(
            endpointId: id,
            status: ConnectionStatus.connected,
            endpointName: id,
          ));
        } else if (status == Status.REJECTED) {
          _connectionUpdateController.add(ConnectionUpdate(
            endpointId: id,
            status: ConnectionStatus.rejected,
            endpointName: id,
          ));
        } else {
          _connectionUpdateController.add(ConnectionUpdate(
            endpointId: id,
            status: ConnectionStatus.error,
            endpointName: id,
            errorMessage: 'Connection failed with status: $status',
          ));
        }
      },
      onDisconnected: (id) {
        VantraLogger.log('NearbyTransport: Disconnected from $id');
        _connectionUpdateController.add(ConnectionUpdate(
          endpointId: id,
          status: ConnectionStatus.disconnected,
          endpointName: id,
        ));
      },
    );
    if (!result) {
      throw const VantraException('Failed to request connection');
    }
  }

  @override
  Future<void> acceptConnection(String endpointId) async {
    VantraLogger.log('NearbyTransport: acceptConnection for $endpointId');
    final result = await _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: (id, payload) {
        VantraLogger.log('NearbyTransport: Payload received from $id');
        if (payload.type == PayloadType.BYTES && payload.bytes != null) {
          _payloadReceivedController.add(PayloadReceivedEvent(
            endpointId: id,
            bytes: payload.bytes!,
          ));
        }
      },
      onPayloadTransferUpdate: (id, update) {
        VantraLogger.log('NearbyTransport: Payload update for $id status: ${update.status}');
      },
    );
    if (!result) {
      throw const VantraException('Failed to accept connection');
    }
  }

  @override
  Future<void> rejectConnection(String endpointId) async {
    VantraLogger.log('NearbyTransport: rejectConnection for $endpointId');
    final result = await _nearby.rejectConnection(endpointId);
    if (!result) {
      throw const VantraException('Failed to reject connection');
    }
  }

  @override
  Future<void> disconnect(String endpointId) async {
    VantraLogger.log('NearbyTransport: disconnect from $endpointId');
    await _nearby.disconnectFromEndpoint(endpointId);
  }

  @override
  Future<void> send(String endpointId, Uint8List data) async {
    VantraLogger.log('NearbyTransport: send data to $endpointId');
    await _nearby.sendBytesPayload(endpointId, data);
  }
}
