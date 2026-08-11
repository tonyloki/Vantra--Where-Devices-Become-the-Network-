// ignore_for_file: avoid_print

import 'dart:async';
import 'package:flutter/services.dart';
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
  bool _isAdvertising = false;
  bool _isDiscovering = false;

  @override
  Stream<List<DiscoveredPeer>> get discoveredPeersStream => _discoveredPeersController.stream;

  @override
  Stream<ConnectionUpdate> get connectionUpdateStream => _connectionUpdateController.stream;

  @override
  Stream<PayloadReceivedEvent> get payloadReceivedStream => _payloadReceivedController.stream;

  @override
  Future<void> startAdvertising(String localName) async {
    if (_isAdvertising) {
      VantraLogger.log('NearbyTransport: Already advertising, skipping startAdvertising');
      return;
    }
    VantraLogger.log('NearbyTransport: startAdvertising for $localName');
    try {
      final result = await _nearby.startAdvertising(
        localName,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: (id, info) {
          VantraLogger.log('NearbyTransport: Connection initiated by $id (${info.endpointName})');
          print('[VANTRA][NEARBY] CONNECTION_INITIATED endpoint=$id name=${info.endpointName}');
          print('[VANTRA][NEARBY] REQUEST_INFO_CREATED endpoint=$id');
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
          print('[VANTRA][NEARBY] CONNECTION_RESULT endpoint=$id status=$status');
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
      _isAdvertising = true;
    } on PlatformException catch (e) {
      final isAlreadyAdvertising = e.code == '8001' ||
          e.message?.contains('STATUS_ALREADY_ADVERTISING') == true ||
          e.toString().contains('8001') ||
          e.toString().contains('STATUS_ALREADY_ADVERTISING');
      if (isAlreadyAdvertising) {
        VantraLogger.log('NearbyTransport: Native reported already advertising. Reconciling state.');
        _isAdvertising = true;
      } else {
        rethrow;
      }
    }
  }

  @override
  Future<void> stopAdvertising() async {
    VantraLogger.log('NearbyTransport: stopAdvertising');
    _isAdvertising = false;
    await _nearby.stopAdvertising();
  }

  @override
  Future<void> startDiscovery(String localName) async {
    if (_isDiscovering) {
      VantraLogger.log('NearbyTransport: Already discovering, skipping startDiscovery');
      return;
    }
    VantraLogger.log('NearbyTransport: startDiscovery for $localName');
    _discoveredPeers.clear();
    _discoveredPeersController.add(List.unmodifiable(_discoveredPeers));

    try {
      final result = await _nearby.startDiscovery(
        localName,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound: (id, name, serviceId) {
          VantraLogger.log('NearbyTransport: Endpoint found $id ($name)');
          print('[VANTRA][NEARBY] DISCOVERED endpoint=$id name=$name');
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
      _isDiscovering = true;
    } on PlatformException catch (e) {
      final isAlreadyDiscovering = e.code == '8002' ||
          e.message?.contains('STATUS_ALREADY_DISCOVERING') == true ||
          e.toString().contains('8002') ||
          e.toString().contains('STATUS_ALREADY_DISCOVERING');
      if (isAlreadyDiscovering) {
        VantraLogger.log('NearbyTransport: Native reported already discovering. Reconciling state.');
        _isDiscovering = true;
      } else {
        rethrow;
      }
    }
  }

  @override
  Future<void> stopDiscovery() async {
    VantraLogger.log('NearbyTransport: stopDiscovery');
    _isDiscovering = false;
    await _nearby.stopDiscovery();
    _discoveredPeers.clear();
    _discoveredPeersController.add(List.unmodifiable(_discoveredPeers));
  }

  @override
  Future<void> connect(String localName, String endpointId) async {
    VantraLogger.log('NearbyTransport: connect to $endpointId');
    final result = await _nearby.requestConnection(
      localName,
      endpointId,
      onConnectionInitiated: (id, info) {
        VantraLogger.log('NearbyTransport: Connection initiated with $id (${info.endpointName})');
        print('[VANTRA][NEARBY] CONNECTION_INITIATED endpoint=$id name=${info.endpointName}');
        print('[VANTRA][NEARBY] REQUEST_INFO_CREATED endpoint=$id');
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
        print('[VANTRA][NEARBY] CONNECTION_RESULT endpoint=$id status=$status');
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
    print('[VANTRA][NEARBY] ACCEPT_CONNECTION_CALLED endpoint=$endpointId');
    final result = await _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: (id, payload) {
        VantraLogger.log('NearbyTransport: Payload received from $id');
        if (payload.type == PayloadType.BYTES && payload.bytes != null) {
          VantraLogger.log('[VANTRA][RECEIVE] PAYLOAD RECEIVED endpointId=$id byteLength=${payload.bytes!.length}');
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
    print('[VANTRA][NEARBY] REJECT_CONNECTION_CALLED endpoint=$endpointId');
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
    VantraLogger.log('[VANTRA][TRANSPORT] NEARBY SEND START endpointId=$endpointId byteLength=${data.length}');
    try {
      await _nearby.sendBytesPayload(endpointId, data);
      VantraLogger.log('[VANTRA][TRANSPORT] NEARBY SEND SUCCESS endpointId=$endpointId');
    } catch (e) {
      VantraLogger.log('[VANTRA][TRANSPORT] NEARBY SEND FAILED endpointId=$endpointId errorType=${e.runtimeType}');
      rethrow;
    }
  }
}
