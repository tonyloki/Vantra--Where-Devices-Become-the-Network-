import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/networking/nearby_connection_service.dart';
import 'package:vantra/core/utils/permissions.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';

class PocPage extends ConsumerStatefulWidget {
  const PocPage({super.key});

  @override
  ConsumerState<PocPage> createState() => _PocPageState();
}

class _PocPageState extends ConsumerState<PocPage> {
  bool _permissionsGranted = false;
  bool _locationServiceEnabled = false;

  List<String> _logs = [];
  final List<String> _receivedTelemetry = [];

  StreamSubscription? _peersSub;
  StreamSubscription? _connSub;
  StreamSubscription? _payloadSub;
  StreamSubscription? _logsSub;

  List<DiscoveredPeer> _discoveredPeers = [];
  final ProtobufCodec _codec = const ProtobufCodec();

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _subscribeToTelemetry();
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _connSub?.cancel();
    _payloadSub?.cancel();
    _logsSub?.cancel();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    final gpsEnabled = await VantraPermissions.isLocationServiceEnabled();
    final granted = await VantraPermissions.requestNearbyPermissions();
    setState(() {
      _locationServiceEnabled = gpsEnabled;
      _permissionsGranted = granted;
    });
    _log('Permissions: ${granted ? "GRANTED" : "DENIED"}, GPS Service: ${gpsEnabled ? "ON" : "OFF"}');
  }

  void _subscribeToTelemetry() {
    final transport = ref.read(transportProvider);
    final nearbyService = ref.read(nearbyConnectionServiceProvider.notifier);

    _logs = List.from(nearbyService.diagnosticLogs);
    _logsSub = nearbyService.diagnosticLogsStream.listen((logs) {
      if (mounted) {
        setState(() {
          _logs = logs;
        });
      }
    });

    _peersSub = transport.discoveredPeersStream.listen((peers) {
      if (mounted) {
        setState(() {
          _discoveredPeers = peers;
        });
        _log('[VANTRA][NEARBY] Discovered peers count: ${peers.length}');
      }
    });

    _connSub = transport.connectionUpdateStream.listen((update) {
      if (mounted) {
        _log('[VANTRA][CONNECTION] Update: ${update.endpointId} status=${update.status.name}');
      }
    });

    _payloadSub = transport.payloadReceivedStream.listen((event) {
      if (mounted) {
        String envelopeInfo = 'UNKNOWN';
        try {
          final envelope = _codec.decodeWireEnvelope(event.bytes);
          envelopeInfo = envelope.runtimeType.toString();
        } catch (_) {
          envelopeInfo = 'RAW_OR_ENCRYPTED';
        }

        final telemetryMsg = '[VANTRA] PAYLOAD_RECEIVED endpoint=${event.endpointId} bytes=${event.bytes.length} type=$envelopeInfo';
        setState(() {
          _receivedTelemetry.add(telemetryMsg);
          if (_receivedTelemetry.length > 50) {
            _receivedTelemetry.removeAt(0);
          }
        });
        _log(telemetryMsg);
      }
    });
  }

  void _log(String msg) {
    ref.read(nearbyConnectionServiceProvider.notifier).appendDiagnosticLog(
      '[${DateTime.now().toIso8601String().substring(11, 19)}] $msg',
    );
  }

  String _formatConnectionStatus(ConnectionStatus status, String? activeId, String? activeName) {
    if (status == ConnectionStatus.connected && activeId != null) {
      return 'Connected: $activeName ($activeId)';
    }
    switch (status) {
      case ConnectionStatus.connecting:
        return 'Connecting...';
      case ConnectionStatus.accepting:
        return 'Accepting...';
      case ConnectionStatus.connected:
        return 'Transport Connected';
      default:
        return 'Idle / Disconnected';
    }
  }

  @override
  Widget build(BuildContext context) {
    final messagingState = ref.watch(messagingStateProvider);
    final nearbyState = ref.watch(nearbyConnectionServiceProvider);
    final localIdentity = ref.watch(localIdentityStateProvider);

    final activeEndpointId = messagingState.activeEndpointId;
    final activeEndpointName = messagingState.activeEndpointName;
    final connectionStatus = messagingState.connectionStatus;

    final activeSession = messagingState.sessions.values
        .where((s) => s.status == SessionStatus.connected && s.isSecure)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VANTRA Diagnostic Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear Console',
            onPressed: () {
              ref.read(nearbyConnectionServiceProvider.notifier).clearDiagnosticLogs();
              setState(() {
                _receivedTelemetry.clear();
              });
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Permissions Status Card
              Card(
                color: _permissionsGranted && _locationServiceEnabled ? Colors.green.shade900 : Colors.red.shade900,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Icon(
                        _permissionsGranted && _locationServiceEnabled ? Icons.check_circle : Icons.warning,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Permissions: ${_permissionsGranted ? "Granted" : "Required"}',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            Text(
                              'Location GPS: ${_locationServiceEnabled ? "Enabled" : "Disabled"}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        onPressed: _checkPermissions,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Local Identity Info
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Local Peer: ${localIdentity.displayName}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('Peer ID: ${localIdentity.peerId}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      if (localIdentity.fingerprint.isNotEmpty)
                        Text('Fingerprint: ${localIdentity.fingerprint}', style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Nearby Lifecycle Status & Controls
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Nearby Lifecycle (Production Singleton)', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Chip(
                            avatar: Icon(nearbyState.isAdvertising ? Icons.sensors : Icons.sensors_off, size: 16),
                            label: Text(nearbyState.isAdvertising ? 'Advertising ON' : 'Advertising OFF'),
                            backgroundColor: nearbyState.isAdvertising ? Colors.green.shade800 : Colors.grey.shade800,
                          ),
                          const SizedBox(width: 8),
                          Chip(
                            avatar: Icon(nearbyState.isDiscovering ? Icons.radar : Icons.radar, size: 16),
                            label: Text(nearbyState.isDiscovering ? 'Discovery ON' : 'Discovery OFF'),
                            backgroundColor: nearbyState.isDiscovering ? Colors.green.shade800 : Colors.grey.shade800,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Re-Initialize Global Service'),
                            onPressed: () async {
                              _log('Requesting global service initialization...');
                              await ref.read(nearbyConnectionServiceProvider.notifier).initialize();
                            },
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop All'),
                            onPressed: () async {
                              _log('Requesting global service stop...');
                              await ref.read(nearbyConnectionServiceProvider.notifier).stopAll();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Connection & Session State
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Connection Status:', style: TextStyle(fontWeight: FontWeight.bold)),
                          Chip(
                            label: Text(_formatConnectionStatus(connectionStatus, activeEndpointId, activeEndpointName)),
                            backgroundColor: activeSession != null
                                ? Colors.green.shade800
                                : (activeEndpointId != null ? Colors.orange.shade800 : Colors.blueGrey.shade800),
                          ),
                        ],
                      ),
                      if (activeSession != null) ...[
                        const SizedBox(height: 8),
                        Text('Secure Session Ready with ${activeSession.displayName} (${activeSession.peerId})',
                            style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          key: const Key('poc_open_chat_button'),
                          icon: const Icon(Icons.chat),
                          label: const Text('Open Chat'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
                          onPressed: () {
                            context.push('/chat/${activeSession.peerId}');
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Discovered Peers List
              const Text('Discovered Endpoints (Nearby):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              if (_discoveredPeers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12.0),
                  child: Text('No endpoints discovered in range.', style: TextStyle(color: Colors.grey)),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _discoveredPeers.length,
                  itemBuilder: (context, index) {
                    final peer = _discoveredPeers[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.devices),
                        title: Text(peer.name),
                        subtitle: Text('Endpoint ID: ${peer.id}'),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 12),

              // Received Payload Telemetry
              const Text('Payload Diagnostic Telemetry (Binary Safe):', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                height: 120,
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade700),
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.black87,
                ),
                child: _receivedTelemetry.isEmpty
                    ? const Center(child: Text('No telemetry events.', style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _receivedTelemetry.length,
                        itemBuilder: (context, index) {
                          return Text(
                            _receivedTelemetry[index],
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.cyanAccent),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),

              // System Console Log
              const Text('System Console Log:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                height: 160,
                width: double.infinity,
                color: Colors.black,
                padding: const EdgeInsets.all(8.0),
                child: _logs.isEmpty
                    ? const Text('System console ready.', style: TextStyle(color: Colors.green, fontFamily: 'monospace'))
                    : ListView.builder(
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          return Text(
                            _logs[index],
                            style: const TextStyle(color: Colors.green, fontFamily: 'monospace', fontSize: 12),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
