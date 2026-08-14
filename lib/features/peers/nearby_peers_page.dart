// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';
import 'package:vantra/core/networking/nearby_connection_service.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';

class NearbyPeersPage extends ConsumerStatefulWidget {
  const NearbyPeersPage({super.key});

  @override
  ConsumerState<NearbyPeersPage> createState() => _NearbyPeersPageState();
}

class _NearbyPeersPageState extends ConsumerState<NearbyPeersPage> {
  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(nearbyConnectionServiceProvider);
    final discoveryService = ref.watch(peerDiscoveryServiceProvider);
    final isDiscovering = ref.watch(isDiscoveringProvider).value ?? false;
    final nearbyPeersAsync = ref.watch(discoveredNearbyPeersProvider);
    final messagingState = ref.watch(messagingStateProvider);
    final localIdentity = ref.watch(localIdentityStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        actions: [
          IconButton(
            icon: Icon(isDiscovering ? Icons.stop_circle_outlined : Icons.play_circle_outline_rounded),
            tooltip: isDiscovering ? 'Stop Scanning' : 'Start Scanning',
            color: isDiscovering ? VantraTheme.amberWarning : VantraTheme.greenVerified,
            onPressed: () {
              if (isDiscovering) {
                ref.read(nearbyConnectionServiceProvider.notifier).stopAll();
              } else {
                ref.read(nearbyConnectionServiceProvider.notifier).initialize();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (connectionState.status != NearbyServiceStatus.ready)
            _buildGlobalStatusBanner(connectionState),
          
          // Scanning status banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: const BoxDecoration(
              color: VantraTheme.surface,
              border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
            ),
            child: Row(
              children: [
                if (isDiscovering)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: VantraTheme.primary),
                  )
                else
                  const Icon(Icons.radar_rounded, size: 18, color: VantraTheme.textMuted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isDiscovering
                        ? 'Scanning for offline peers nearby...'
                        : 'Scanning paused. Tap start to discover.',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDiscovering ? VantraTheme.textPrimary : VantraTheme.textSecondary,
                      fontWeight: isDiscovering ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    if (isDiscovering) {
                      ref.read(nearbyConnectionServiceProvider.notifier).stopAll();
                    } else {
                      ref.read(nearbyConnectionServiceProvider.notifier).initialize();
                    }
                  },
                  child: Text(
                    isDiscovering ? 'STOP' : 'SCAN',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
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
                          if (isDiscovering)
                            const ScanningPulseCircle()
                          else
                            Icon(
                              Icons.wifi_tethering_off_rounded,
                              size: 64,
                              color: VantraTheme.textMuted.withValues(alpha: 0.5),
                            ),
                          const SizedBox(height: 24),
                          Text(
                            isDiscovering ? 'Searching for devices nearby' : 'No devices found',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Ensure the other device is advertising or in range with Wi-Fi & Bluetooth enabled.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: VantraTheme.textSecondary, fontSize: 13, height: 1.4),
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
                    final resolvedPeerId = peer.resolvedPeerId ?? messagingState.endpointToPeerId[peer.endpointId];
                    final session = resolvedPeerId != null ? messagingState.sessions[resolvedPeerId] : null;
                    final isConnected = session?.status == SessionStatus.connected;
                    final isConnecting = peer.isConnecting || session?.status == SessionStatus.connecting || session?.status == SessionStatus.handshaking;

                    final remotePeerId = peer.resolvedPeerId;
                    final isInitiator = remotePeerId != null && localIdentity.peerId.isNotEmpty && localIdentity.peerId.compareTo(remotePeerId) < 0;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      leading: CircleAvatar(
                        radius: 24,
                        backgroundColor: isConnected
                            ? VantraTheme.greenVerified.withValues(alpha: 0.15)
                            : VantraTheme.primary.withValues(alpha: 0.15),
                        child: Icon(
                          isConnected ? Icons.lock_outline_rounded : Icons.cell_tower_rounded,
                          color: isConnected ? VantraTheme.greenVerified : VantraTheme.primaryAccent,
                          size: 22,
                        ),
                      ),
                      title: Text(
                        peer.effectiveName,
                        style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
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
                              ? VantraTheme.greenVerified
                              : isConnecting
                                  ? VantraTheme.amberWarning
                                  : VantraTheme.textSecondary,
                        ),
                      ),
                      trailing: isConnected
                          ? ElevatedButton.icon(
                              onPressed: () => context.push('/chat/$resolvedPeerId'),
                              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15),
                              label: const Text('Chat'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: VantraTheme.greenVerified,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              ),
                            )
                          : isConnecting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: VantraTheme.primary),
                                )
                              : isInitiator
                                  ? OutlinedButton(
                                      onPressed: () {
                                        print('[VANTRA][CONNECTION] CONNECT_BUTTON_PRESSED: endpointId=${peer.endpointId}, name=${peer.effectiveName}');
                                        final displayName = localIdentity.displayName.isNotEmpty
                                            ? localIdentity.displayName
                                            : 'VantraDevice';
                                        discoveryService.connect(
                                          peer.endpointId,
                                          localName: '$displayName:${localIdentity.peerId}',
                                        );
                                      },
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      ),
                                      child: const Text('Connect'),
                                    )
                                  : const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                                      child: Text(
                                        'Waiting for connection…',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: VantraTheme.textSecondary,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator(color: VantraTheme.primary)),
              error: (err, _) => Center(
                child: Text(
                  'Error: $err',
                  style: const TextStyle(color: VantraTheme.redBlocked),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlobalStatusBanner(NearbyConnectionState state) {
    String message = '';
    String buttonText = '';
    Color color = VantraTheme.amberWarning;
    VoidCallback? onPressed;

    if (state.status == NearbyServiceStatus.permissionsRequired) {
      message = 'Nearby permissions are required to discover peers.';
      buttonText = 'GRANT';
      color = VantraTheme.redBlocked;
      onPressed = () => ref.read(nearbyConnectionServiceProvider.notifier).initialize();
    } else if (state.status == NearbyServiceStatus.locationDisabled) {
      message = 'Location services (GPS) are disabled.';
      buttonText = 'ENABLE';
      color = VantraTheme.amberWarning;
      onPressed = () => ref.read(nearbyConnectionServiceProvider.notifier).initialize();
    } else if (state.status == NearbyServiceStatus.error) {
      message = 'Error: ${state.errorMessage}';
      buttonText = 'RETRY';
      color = VantraTheme.redBlocked;
      onPressed = () => ref.read(nearbyConnectionServiceProvider.notifier).initialize();
    } else if (state.status == NearbyServiceStatus.initializing) {
      message = 'Initializing Nearby services...';
      color = VantraTheme.primary;
    }

    if (message.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          if (onPressed != null)
            ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                foregroundColor: color == VantraTheme.amberWarning ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
              child: Text(
                buttonText,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }
}

class ScanningPulseCircle extends StatefulWidget {
  const ScanningPulseCircle({super.key});

  @override
  State<ScanningPulseCircle> createState() => _ScanningPulseCircleState();
}

class _ScanningPulseCircleState extends State<ScanningPulseCircle> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 80 + (progress * 120),
              height: 80 + (progress * 120),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: VantraTheme.primary.withValues(alpha: (1.0 - progress) * 0.4),
                  width: 2,
                ),
              ),
            ),
            Container(
              width: 80 + (((progress + 0.5) % 1.0) * 120),
              height: 80 + (((progress + 0.5) % 1.0) * 120),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: VantraTheme.primary.withValues(alpha: (1.0 - ((progress + 0.5) % 1.0)) * 0.2),
                  width: 2,
                ),
              ),
            ),
            CircleAvatar(
              radius: 40,
              backgroundColor: VantraTheme.primary.withValues(alpha: 0.1),
              child: const Icon(
                Icons.wifi_tethering_rounded,
                size: 36,
                color: VantraTheme.primaryAccent,
              ),
            ),
          ],
        );
      },
    );
  }
}
