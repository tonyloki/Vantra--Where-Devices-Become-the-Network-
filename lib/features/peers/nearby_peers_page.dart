import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/peers/peer_provider.dart';

class NearbyPeersPage extends ConsumerStatefulWidget {
  const NearbyPeersPage({super.key});

  @override
  ConsumerState<NearbyPeersPage> createState() => _NearbyPeersPageState();
}

class _NearbyPeersPageState extends ConsumerState<NearbyPeersPage> {
  @override
  void initState() {
    super.initState();
    // Proactively start discovery when opening page
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(peerDiscoveryServiceProvider).startDiscovery();
    });
  }

  @override
  Widget build(BuildContext context) {
    final discoveryService = ref.watch(peerDiscoveryServiceProvider);
    final isDiscovering = ref.watch(isDiscoveringProvider).value ?? false;
    final nearbyPeersAsync = ref.watch(discoveredNearbyPeersProvider);
    final messagingState = ref.watch(messagingStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: Icon(isDiscovering ? Icons.stop_circle_outlined : Icons.play_circle_outline),
            tooltip: isDiscovering ? 'Stop Scanning' : 'Start Scanning',
            color: isDiscovering ? Colors.amberAccent : Colors.greenAccent,
            onPressed: () {
              if (isDiscovering) {
                discoveryService.stopDiscovery();
              } else {
                discoveryService.startDiscovery();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Scanning status banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            color: isDiscovering ? Colors.deepPurple.shade900.withValues(alpha: 0.4) : const Color(0xFF1E1E1E),
            child: Row(
              children: [
                if (isDiscovering)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurpleAccent),
                  )
                else
                  const Icon(Icons.radar_outlined, size: 20, color: Colors.grey),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isDiscovering
                        ? 'Scanning for offline peers nearby...'
                        : 'Scanning paused. Tap start to find devices.',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDiscovering ? Colors.white : Colors.grey,
                      fontWeight: isDiscovering ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    if (isDiscovering) {
                      discoveryService.stopDiscovery();
                    } else {
                      discoveryService.startDiscovery();
                    }
                  },
                  child: Text(isDiscovering ? 'STOP' : 'SCAN'),
                ),
              ],
            ),
          ),

          Expanded(
            child: nearbyPeersAsync.when(
              data: (peers) {
                if (peers.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isDiscovering ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                            size: 64,
                            color: isDiscovering ? Colors.deepPurpleAccent : Colors.grey,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            isDiscovering ? 'Searching for devices nearby' : 'No devices found',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Ensure the other device is advertising or in range with Wi-Fi & Bluetooth enabled.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: peers.length,
                  separatorBuilder: (context, index) => const Divider(height: 1, indent: 72, color: Colors.white10),
                  itemBuilder: (context, index) {
                    final peer = peers[index];
                    final resolvedPeerId = messagingState.endpointToPeerId[peer.endpointId];
                    final session = resolvedPeerId != null ? messagingState.sessions[resolvedPeerId] : null;
                    final isConnected = session?.status == SessionStatus.connected;
                    final isConnecting = peer.isConnecting || session?.status == SessionStatus.connecting || session?.status == SessionStatus.handshaking;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      leading: CircleAvatar(
                        radius: 24,
                        backgroundColor: isConnected ? Colors.green.shade800 : Colors.deepPurple.shade700,
                        child: Icon(
                          isConnected ? Icons.lock : Icons.devices,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      title: Text(
                        peer.effectiveName,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        isConnected
                            ? 'Securely Connected'
                            : isConnecting
                                ? 'Connecting & Handshaking...'
                                : 'Available Nearby',
                        style: TextStyle(
                          fontSize: 13,
                          color: isConnected
                              ? Colors.greenAccent
                              : isConnecting
                                  ? Colors.amberAccent
                                  : Colors.grey,
                        ),
                      ),
                      trailing: isConnected
                          ? ElevatedButton.icon(
                              onPressed: () => context.push('/chat/$resolvedPeerId'),
                              icon: const Icon(Icons.chat, size: 16),
                              label: const Text('Chat'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              ),
                            )
                          : isConnecting
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2.5),
                                )
                              : OutlinedButton(
                                  onPressed: () => discoveryService.connect(peer.endpointId),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.deepPurpleAccent,
                                    side: const BorderSide(color: Colors.deepPurpleAccent),
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  ),
                                  child: const Text('Connect'),
                                ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(child: Text('Error: $err', style: const TextStyle(color: Colors.redAccent))),
            ),
          ),
        ],
      ),
    );
  }
}
