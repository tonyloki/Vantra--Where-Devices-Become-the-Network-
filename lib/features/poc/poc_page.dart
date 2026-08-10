import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/utils/permissions.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_session.dart';

class PocPage extends ConsumerStatefulWidget {
  const PocPage({super.key});

  @override
  ConsumerState<PocPage> createState() => _PocPageState();
}

class _PocPageState extends ConsumerState<PocPage> {
  bool _permissionsGranted = false;
  bool _locationServiceEnabled = false;

  String _localDeviceName = '';
  bool _isAdvertising = false;
  bool _isDiscovering = false;

  List<DiscoveredPeer> _discoveredPeers = [];
  final List<String> _logs = [];
  final List<String> _receivedMessages = [];



  StreamSubscription? _peersSub;
  StreamSubscription? _connSub;
  StreamSubscription? _payloadSub;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _messageController = TextEditingController(text: 'HELLO VANTRA');

  @override
  void initState() {
    super.initState();
    
    // Read display name from local identity provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final localId = ref.read(localIdentityStateProvider);
      setState(() {
        _localDeviceName = localId.displayName;
        _nameController.text = _localDeviceName;
      });
    });

    _checkAndRequestPermissions();
    _subscribeToTransport();
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _connSub?.cancel();
    _payloadSub?.cancel();
    _nameController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _checkAndRequestPermissions() async {
    final gpsEnabled = await VantraPermissions.isLocationServiceEnabled();
    final granted = await VantraPermissions.requestNearbyPermissions();
    setState(() {
      _locationServiceEnabled = gpsEnabled;
      _permissionsGranted = granted;
    });
    _log('Permissions: ${granted ? "GRANTED" : "DENIED"}, GPS Service: ${gpsEnabled ? "ON" : "OFF"}');
  }

  void _subscribeToTransport() {
    final transport = ref.read(transportProvider);

    _peersSub = transport.discoveredPeersStream.listen((peers) {
      setState(() {
        _discoveredPeers = peers;
      });
      _log('Discovered peers count: ${peers.length}');
    });

    _connSub = transport.connectionUpdateStream.listen((update) {
      _log('Connection update: ${update.endpointId} status: ${update.status.name}');

      if (update.status == ConnectionStatus.connecting) {
        _showConnectionRequestDialog(update.endpointId, update.endpointName, update.authenticationToken, update.isIncoming);
      }
    });

    _payloadSub = transport.payloadReceivedStream.listen((event) {
      try {
        final decoded = utf8.decode(event.bytes);
        setState(() {
          _receivedMessages.add('${event.endpointId}: $decoded');
        });
        _log('Payload received from ${event.endpointId}: "$decoded"');
      } catch (e) {
        setState(() {
          _receivedMessages.add('${event.endpointId}: [Raw Bytes ${event.bytes.length}]');
        });
        _log('Failed to decode payload from ${event.endpointId} as UTF-8');
      }
    });
  }

  String _getStatusInfo(String? activeId, String? activeName, ConnectionStatus status) {
    if (status == ConnectionStatus.connected && activeId != null) {
      return 'Connected to $activeName ($activeId)';
    }
    switch (status) {
      case ConnectionStatus.connecting:
        return 'Connecting...';
      case ConnectionStatus.discovering:
        return 'Discovering...';
      case ConnectionStatus.advertising:
        return 'Advertising...';
      default:
        return 'Idle';
    }
  }

  void _log(String msg) {
    setState(() {
      _logs.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $msg');
    });
  }

  void _showConnectionRequestDialog(String endpointId, String name, String? token, bool isIncoming) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text(isIncoming ? 'Incoming Connection Request' : 'Outgoing Connection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Device: $name'),
              Text('ID: $endpointId'),
              if (token != null) Text('Auth Token: $token'),
              const SizedBox(height: 8),
              Text(isIncoming 
                  ? 'Accept connection request?' 
                  : 'Confirm matching Auth Token to establish connection?'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _rejectConnection(endpointId);
              },
              child: const Text('REJECT', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _acceptConnection(endpointId);
              },
              child: const Text('ACCEPT'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _startAdvertising() async {
    if (!_permissionsGranted) {
      _log('Cannot advertise: permissions not granted');
      return;
    }
    try {
      await ref.read(transportProvider).startAdvertising(_localDeviceName);
      setState(() {
        _isAdvertising = true;
      });
      _log('Advertising started as "$_localDeviceName"');
    } catch (e) {
      _log('Start advertising failed: $e');
    }
  }

  Future<void> _stopAdvertising() async {
    try {
      await ref.read(transportProvider).stopAdvertising();
      setState(() {
        _isAdvertising = false;
      });
      _log('Advertising stopped');
    } catch (e) {
      _log('Stop advertising failed: $e');
    }
  }

  Future<void> _startDiscovery() async {
    if (!_permissionsGranted) {
      _log('Cannot discover: permissions not granted');
      return;
    }
    try {
      await ref.read(transportProvider).startDiscovery(_localDeviceName);
      setState(() {
        _isDiscovering = true;
      });
      _log('Discovery started as "$_localDeviceName"');
    } catch (e) {
      _log('Start discovery failed: $e');
    }
  }

  Future<void> _stopDiscovery() async {
    try {
      await ref.read(transportProvider).stopDiscovery();
      setState(() {
        _isDiscovering = false;
      });
      _log('Discovery stopped');
    } catch (e) {
      _log('Stop discovery failed: $e');
    }
  }

  Future<void> _connectTo(String endpointId) async {
    try {
      _log('Initiating connection request to $endpointId');
      await ref.read(transportProvider).connect(_localDeviceName, endpointId);
    } catch (e) {
      _log('Connection request failed: $e');
    }
  }

  Future<void> _acceptConnection(String endpointId) async {
    try {
      _log('Accepting connection with $endpointId');
      await ref.read(transportProvider).acceptConnection(endpointId);
    } catch (e) {
      _log('Accept connection failed: $e');
    }
  }

  Future<void> _rejectConnection(String endpointId) async {
    try {
      _log('Rejecting connection with $endpointId');
      await ref.read(transportProvider).rejectConnection(endpointId);
    } catch (e) {
      _log('Reject connection failed: $e');
    }
  }

  Future<void> _disconnect() async {
    final target = ref.read(messagingStateProvider).activeEndpointId;
    if (target != null) {
      try {
        _log('Disconnecting from $target');
        await ref.read(transportProvider).disconnect(target);
      } catch (e) {
        _log('Disconnect failed: $e');
      }
    }
  }

  Future<void> _sendPayload() async {
    final target = ref.read(messagingStateProvider).activeEndpointId;
    final text = _messageController.text;
    if (target != null && text.isNotEmpty) {
      try {
        _log('Sending: "$text" to $target');
        final bytes = Uint8List.fromList(utf8.encode(text));
        await ref.read(transportProvider).send(target, bytes);
      } catch (e) {
        _log('Send payload failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messagingState = ref.watch(messagingStateProvider);
    final activeEndpointId = messagingState.activeEndpointId;
    final activeEndpointName = messagingState.activeEndpointName;
    final connectionStatus = messagingState.connectionStatus;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VANTRA Communication POC'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Permissions status card
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
                              'Location GPS: ${_locationServiceEnabled ? "Enabled" : "Disabled (Must be turned ON)"}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        onPressed: _checkAndRequestPermissions,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Local device name configuration
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Local Device Display Name',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        setState(() {
                          _localDeviceName = val;
                        });
                        ref.read(localIdentityStateProvider.notifier).updateDisplayName(val);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Advertising & Discovery Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: _isAdvertising ? _stopAdvertising : _startAdvertising,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isAdvertising ? Colors.red.shade700 : null,
                    ),
                    child: Text(_isAdvertising ? 'Stop Advertising' : 'Start Advertising'),
                  ),
                  ElevatedButton(
                    onPressed: _isDiscovering ? _stopDiscovery : _startDiscovery,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isDiscovering ? Colors.red.shade700 : null,
                    ),
                    child: Text(_isDiscovering ? 'Stop Discovery' : 'Start Discovery'),
                  ),
                ],
              ),
              const Divider(height: 32),

              // Connection status
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Connection Status:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Chip(
                    label: Text(_getStatusInfo(activeEndpointId, activeEndpointName, connectionStatus)),
                    backgroundColor: activeEndpointId != null ? Colors.green.shade800 : Colors.blueGrey.shade800,
                  ),
                ],
              ),

              if (activeEndpointId != null) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _disconnect,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade900),
                      child: const Text('Disconnect'),
                    ),
                    Consumer(
                      builder: (context, ref, child) {
                        final messagingState = ref.watch(messagingStateProvider);
                        final activeSession = messagingState.sessions.values
                            .where((s) => s.status == SessionStatus.connected)
                            .firstOrNull;
                        if (activeSession == null) {
                          return const SizedBox.shrink();
                        }
                        return ElevatedButton(
                          key: const Key('poc_open_chat_button'),
                          onPressed: () {
                            context.push('/chat/${activeSession.peerId}');
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
                          child: const Text('Open Chat'),
                        );
                      },
                    ),
                  ],
                ),
              ],
              const Divider(height: 32),

              // Discovered peers list
              const Text('Discovered Peers:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              if (_discoveredPeers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12.0),
                  child: Text('No peers discovered yet. Try starting discovery.', style: TextStyle(color: Colors.grey)),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _discoveredPeers.length,
                  itemBuilder: (context, index) {
                    final peer = _discoveredPeers[index];
                    return ListTile(
                      title: Text(peer.name),
                      subtitle: Text(peer.id),
                      trailing: ElevatedButton(
                        onPressed: () => _connectTo(peer.id),
                        child: const Text('Connect'),
                      ),
                    );
                  },
                ),
              const Divider(height: 32),

              // Payload Transmission Section
              const Text('Payload Transmission:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        labelText: 'Raw Bytes String (UTF-8)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: activeEndpointId != null ? _sendPayload : null,
                    child: const Text('Send'),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Received payloads list
              const Text('Received Payloads:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                height: 120,
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: _receivedMessages.isEmpty
                    ? const Center(child: Text('No payloads received yet.', style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _receivedMessages.length,
                        itemBuilder: (context, index) {
                          return Text(_receivedMessages[index]);
                        },
                      ),
              ),
              const Divider(height: 32),

              // System Log terminal
              const Text('System Console Log:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                height: 150,
                width: double.infinity,
                color: Colors.black,
                padding: const EdgeInsets.all(8.0),
                child: _logs.isEmpty
                    ? const Text('System console active.', style: TextStyle(color: Colors.green, fontFamily: 'monospace'))
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
