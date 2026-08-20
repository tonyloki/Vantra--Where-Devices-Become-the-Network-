import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vantra/core/calls/call_provider.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

class IncomingCallPage extends ConsumerStatefulWidget {
  final String peerId;

  const IncomingCallPage({
    super.key,
    required this.peerId,
  });

  @override
  ConsumerState<IncomingCallPage> createState() => _IncomingCallPageState();
}

class _IncomingCallPageState extends ConsumerState<IncomingCallPage> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerProfileAsync = ref.watch(peerProfileStreamProvider(widget.peerId));
    final peerProfile = peerProfileAsync.value;
    final displayName = peerProfile?.effectiveName ??
        (widget.peerId.length >= 6 ? 'Peer ${widget.peerId.substring(0, 6)}' : widget.peerId);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Background subtle color gradient
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.2,
                  colors: [
                    VantraTheme.primary.withValues(alpha: 0.15),
                    Colors.black,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SizedBox(height: 40),
                // Peer profile info & pulsating avatar
                Column(
                  children: [
                    const Icon(
                      Icons.security,
                      color: VantraTheme.primaryAccent,
                      size: 20,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'VANTRA SECURE CALL',
                      style: TextStyle(
                        color: VantraTheme.textMuted,
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 50),
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, child) {
                        return Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: VantraTheme.primary.withValues(
                              alpha: 0.15 * (1.0 - _pulseController.value),
                            ),
                            border: Border.all(
                              color: VantraTheme.primary.withValues(
                                alpha: 0.4 * (1.0 - _pulseController.value),
                              ),
                              width: 2 + 10 * _pulseController.value,
                            ),
                          ),
                          child: child,
                        );
                      },
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: VantraTheme.surface,
                        ),
                        child: Center(
                          child: Text(
                            displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      displayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Incoming call...',
                      style: TextStyle(
                        color: VantraTheme.textSecondary,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),

                // Accept/Reject action buttons
                Padding(
                  padding: const EdgeInsets.only(bottom: 60.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Decline
                      Column(
                        children: [
                          GestureDetector(
                            onTap: () {
                              ref.read(callStateProvider.notifier).declineCall();
                            },
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.redAccent,
                              ),
                              child: const Icon(
                                Icons.call_end_rounded,
                                color: Colors.white,
                                size: 32,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Decline',
                            style: TextStyle(
                              color: VantraTheme.textSecondary,
                              fontSize: 13,
                            ),
                          )
                        ],
                      ),
                      // Accept
                      Column(
                        children: [
                          GestureDetector(
                            onTap: () {
                              ref.read(callStateProvider.notifier).answerCall();
                            },
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.green,
                              ),
                              child: const Icon(
                                Icons.call_rounded,
                                color: Colors.white,
                                size: 32,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Accept',
                            style: TextStyle(
                              color: VantraTheme.textSecondary,
                              fontSize: 13,
                            ),
                          )
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
