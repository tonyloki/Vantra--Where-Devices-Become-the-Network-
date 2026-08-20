import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vantra/core/calls/call_provider.dart';
import 'package:vantra/core/calls/call_session.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

class ActiveCallPage extends ConsumerStatefulWidget {
  final CallSession session;

  const ActiveCallPage({
    super.key,
    required this.session,
  });

  @override
  ConsumerState<ActiveCallPage> createState() => _ActiveCallPageState();
}

class _ActiveCallPageState extends ConsumerState<ActiveCallPage> with SingleTickerProviderStateMixin {
  late AnimationController _waveformController;
  final List<double> _waveformHeights = List.generate(8, (_) => 10.0);
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _waveformController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..addListener(() {
        if (widget.session.status == CallStatus.active && !widget.session.isMuted) {
          setState(() {
            for (int i = 0; i < _waveformHeights.length; i++) {
              _waveformHeights[i] = 10.0 + _random.nextDouble() * 40.0;
            }
          });
        }
      })..repeat(reverse: true);
  }

  @override
  void dispose() {
    _waveformController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final peerProfileAsync = ref.watch(peerProfileStreamProvider(widget.session.peerId));
    final peerProfile = peerProfileAsync.value;
    final displayName = peerProfile?.effectiveName ??
        (widget.session.peerId.length >= 6
            ? 'Peer ${widget.session.peerId.substring(0, 6)}'
            : widget.session.peerId);

    String statusText = '';
    switch (widget.session.status) {
      case CallStatus.outgoing:
        statusText = 'Calling...';
        break;
      case CallStatus.incoming:
        statusText = 'Incoming call...';
        break;
      case CallStatus.active:
        statusText = _formatDuration(widget.session.duration);
        break;
      case CallStatus.ended:
        statusText = widget.session.error ?? 'Call ended';
        break;
      case CallStatus.idle:
        statusText = '';
        break;
    }

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
                    VantraTheme.primary.withValues(alpha: 0.1),
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
                // Peer name, status, and waveform
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
                    const SizedBox(height: 60),
                    Container(
                      width: 90,
                      height: 90,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: VantraTheme.surface,
                      ),
                      child: Center(
                        child: Text(
                          displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      displayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      statusText,
                      style: TextStyle(
                        color: widget.session.status == CallStatus.active
                            ? VantraTheme.primaryAccent
                            : VantraTheme.textSecondary,
                        fontSize: 18,
                        fontWeight: widget.session.status == CallStatus.active
                            ? FontWeight.bold
                            : FontWeight.normal,
                        letterSpacing: widget.session.status == CallStatus.active ? 1.0 : 0.0,
                      ),
                    ),
                    const SizedBox(height: 40),
                    // Waveform equalizer effect
                    if (widget.session.status == CallStatus.active)
                      SizedBox(
                        height: 60,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(_waveformHeights.length, (index) {
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              width: 6,
                              height: widget.session.isMuted ? 8.0 : _waveformHeights[index],
                              decoration: BoxDecoration(
                                color: VantraTheme.primaryAccent.withValues(
                                  alpha: widget.session.isMuted ? 0.3 : 0.8,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            );
                          }),
                        ),
                      ),
                  ],
                ),

                // Control panel & hangup
                Padding(
                  padding: const EdgeInsets.only(bottom: 60.0),
                  child: Column(
                    children: [
                      // Option buttons (Mute, Speaker)
                      if (widget.session.status == CallStatus.active) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Mute button
                            Column(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    ref.read(callStateProvider.notifier).toggleMute();
                                  },
                                  child: Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: widget.session.isMuted
                                          ? Colors.white
                                          : Colors.white12,
                                    ),
                                    child: Icon(
                                      widget.session.isMuted
                                          ? Icons.mic_off_rounded
                                          : Icons.mic_rounded,
                                      color: widget.session.isMuted
                                          ? Colors.black
                                          : Colors.white,
                                      size: 24,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Mute',
                                  style: TextStyle(
                                    color: VantraTheme.textSecondary,
                                    fontSize: 12,
                                  ),
                                )
                              ],
                            ),
                            const SizedBox(width: 48),
                            // Speaker button
                            Column(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    ref.read(callStateProvider.notifier).toggleSpeaker();
                                  },
                                  child: Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: widget.session.isSpeaker
                                          ? Colors.white
                                          : Colors.white12,
                                    ),
                                    child: Icon(
                                      widget.session.isSpeaker
                                          ? Icons.volume_up_rounded
                                          : Icons.volume_down_rounded,
                                      color: widget.session.isSpeaker
                                          ? Colors.black
                                          : Colors.white,
                                      size: 24,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Speaker',
                                  style: TextStyle(
                                    color: VantraTheme.textSecondary,
                                    fontSize: 12,
                                  ),
                                )
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 48),
                      ],

                      // Hangup button
                      GestureDetector(
                        onTap: () {
                          ref.read(callStateProvider.notifier).endCall();
                        },
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.red,
                          ),
                          child: const Icon(
                            Icons.call_end_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.session.status == CallStatus.ended ? 'Disconnected' : 'End Call',
                        style: const TextStyle(
                          color: VantraTheme.textSecondary,
                          fontSize: 13,
                        ),
                      )
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
