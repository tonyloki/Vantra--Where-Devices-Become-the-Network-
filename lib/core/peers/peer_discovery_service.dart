// ignore_for_file: avoid_print

import 'dart:async';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/utils/logger.dart';

class DiscoveredNearbyPeer {
  final String endpointId;
  final String endpointName;
  final String? resolvedPeerId;
  final String? resolvedNickname;
  final bool isConnecting;
  final bool isConnected;

  const DiscoveredNearbyPeer({
    required this.endpointId,
    required this.endpointName,
    this.resolvedPeerId,
    this.resolvedNickname,
    this.isConnecting = false,
    this.isConnected = false,
  });

  String get effectiveName {
    if (resolvedNickname != null && resolvedNickname!.trim().isNotEmpty) {
      return resolvedNickname!.trim();
    }
    return endpointName;
  }

  DiscoveredNearbyPeer copyWith({
    String? endpointId,
    String? endpointName,
    String? resolvedPeerId,
    String? resolvedNickname,
    bool? isConnecting,
    bool? isConnected,
  }) {
    return DiscoveredNearbyPeer(
      endpointId: endpointId ?? this.endpointId,
      endpointName: endpointName ?? this.endpointName,
      resolvedPeerId: resolvedPeerId ?? this.resolvedPeerId,
      resolvedNickname: resolvedNickname ?? this.resolvedNickname,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}

class PeerDiscoveryService {
  final Transport _transport;
  late final StreamSubscription _discoveredPeersSub;
  late final StreamSubscription _connectionSub;

  final _discoveredController = StreamController<List<DiscoveredNearbyPeer>>.broadcast();
  final _isDiscoveringController = StreamController<bool>.broadcast();

  final Map<String, DiscoveredNearbyPeer> _discoveredMap = {};
  bool _isDiscovering = false;

  Stream<List<DiscoveredNearbyPeer>> get discoveredPeersStream => _discoveredController.stream;
  Stream<bool> get isDiscoveringStream => _isDiscoveringController.stream;
  bool get isDiscovering => _isDiscovering;

  PeerDiscoveryService(this._transport) {
    _discoveredPeersSub = _transport.discoveredPeersStream.listen(_onDiscoveredPeers);
    _connectionSub = _transport.connectionUpdateStream.listen(_onConnectionUpdate);
  }

  Future<void> startDiscovery({String localName = 'VantraDevice'}) async {
    if (_isDiscovering) return;
    VantraLogger.log('[VANTRA][DISCOVERY] Starting nearby discovery');
    _isDiscovering = true;
    _isDiscoveringController.add(true);
    _discoveredMap.clear();
    _discoveredController.add([]);

    try {
      await _transport.startDiscovery(localName);
    } catch (e) {
      _isDiscovering = false;
      _isDiscoveringController.add(false);
      rethrow;
    }
  }

  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;
    VantraLogger.log('[VANTRA][DISCOVERY] Stopping nearby discovery');
    _isDiscovering = false;
    _isDiscoveringController.add(false);
    _discoveredMap.clear();
    _discoveredController.add([]);

    try {
      await _transport.stopDiscovery();
    } catch (_) {}
  }

  Future<void> connect(String endpointId, {String localName = 'VantraDevice'}) async {
    final localIndex = localName.lastIndexOf(':');
    final localPeerId = localIndex != -1 ? localName.substring(localIndex + 1) : '';
    final remotePeer = _discoveredMap[endpointId];
    final remotePeerId = remotePeer?.resolvedPeerId;

    if (localPeerId.isNotEmpty && remotePeerId != null && remotePeerId.isNotEmpty) {
      final role = localPeerId.compareTo(remotePeerId) < 0 ? 'INITIATOR' : 'RESPONDER';
      print('[VANTRA][CONNECTION] ROLE_DECISION localPeerId=$localPeerId remotePeerId=$remotePeerId role=$role');
      if (localPeerId.compareTo(remotePeerId) >= 0) {
        print('[VANTRA][CONNECTION] Aborting connect: local device is the designated RESPONDER for remote peer $remotePeerId');
        return;
      }
    }

    VantraLogger.log('[VANTRA][DISCOVERY] Initiating connection to endpoint $endpointId');
    print('[VANTRA][NEARBY] CONNECT_REQUEST_SENT endpoint=$endpointId');
    if (_discoveredMap.containsKey(endpointId)) {
      _discoveredMap[endpointId] = _discoveredMap[endpointId]!.copyWith(isConnecting: true);
      _discoveredController.add(_discoveredMap.values.toList());
    }
    await _transport.connect(localName, endpointId);
  }

  void _onDiscoveredPeers(List<DiscoveredPeer> rawPeers) {
    final currentEndpoints = <String>{};

    for (final raw in rawPeers) {
      currentEndpoints.add(raw.id);
      final index = raw.name.lastIndexOf(':');
      final name = index != -1 ? raw.name.substring(0, index) : raw.name;
      final peerId = index != -1 ? raw.name.substring(index + 1) : null;

      _discoveredMap[raw.id] = DiscoveredNearbyPeer(
        endpointId: raw.id,
        endpointName: name,
        resolvedPeerId: peerId,
        isConnecting: _discoveredMap[raw.id]?.isConnecting ?? false,
        isConnected: _discoveredMap[raw.id]?.isConnected ?? false,
      );
    }

    // Remove lost endpoints
    _discoveredMap.removeWhere((key, _) => !currentEndpoints.contains(key));
    _discoveredController.add(_discoveredMap.values.toList());
  }

  void _onConnectionUpdate(ConnectionUpdate update) {
    if (_discoveredMap.containsKey(update.endpointId)) {
      final current = _discoveredMap[update.endpointId]!;
      _discoveredMap[update.endpointId] = current.copyWith(
        isConnecting: update.status == ConnectionStatus.connecting,
        isConnected: update.status == ConnectionStatus.connected,
      );
      _discoveredController.add(_discoveredMap.values.toList());
    }
  }

  void dispose() {
    _discoveredPeersSub.cancel();
    _connectionSub.cancel();
    _discoveredController.close();
    _isDiscoveringController.close();
  }
}
