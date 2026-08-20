import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

class VoiceMessageBubble extends StatefulWidget {
  final String filePath;
  final int durationMs;
  final bool isMe;

  const VoiceMessageBubble({
    super.key,
    required this.filePath,
    required this.durationMs,
    required this.isMe,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  late final AudioPlayer _audioPlayer;
  PlayerState _playerState = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  StreamSubscription? _stateSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _duration = Duration(milliseconds: widget.durationMs);

    _stateSubscription = _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _playerState = state;
        });
      }
    });

    _positionSubscription = _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) {
        setState(() {
          _position = pos;
        });
      }
    });

    _durationSubscription = _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) {
        setState(() {
          _duration = dur;
        });
      }
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    try {
      if (_playerState == PlayerState.playing) {
        await _audioPlayer.pause();
      } else {
        final file = File(widget.filePath);
        if (await file.exists()) {
          await _audioPlayer.play(DeviceFileSource(widget.filePath));
        } else {
          debugPrint('Audio file missing at: ${widget.filePath}');
        }
      }
    } catch (e) {
      debugPrint('Playback error: $e');
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = widget.isMe ? Colors.black : Colors.tealAccent;
    final textColor = widget.isMe ? Colors.black.withOpacity(0.8) : Colors.white;
    final progress = _duration.inMilliseconds > 0 
        ? _position.inMilliseconds / _duration.inMilliseconds 
        : 0.0;

    return Container(
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(maxWidth: 260),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(
              _playerState == PlayerState.playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
              color: accentColor,
              size: 38,
            ),
            onPressed: _togglePlayback,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Premium visual Waveform
                CustomPaint(
                  size: const Size(double.infinity, 24),
                  painter: _WaveformPainter(
                    progress: progress,
                    waveColor: widget.isMe ? Colors.black.withOpacity(0.2) : Colors.grey[700]!,
                    activeColor: accentColor,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_position),
                      style: TextStyle(
                        color: textColor.withOpacity(0.7),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      _formatDuration(_duration),
                      style: TextStyle(
                        color: textColor.withOpacity(0.7),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final double progress;
  final Color waveColor;
  final Color activeColor;

  static const List<double> _waveformHeights = [
    0.3, 0.4, 0.6, 0.3, 0.5, 0.8, 0.7, 0.4, 0.3, 0.6,
    0.9, 0.5, 0.4, 0.7, 0.6, 0.3, 0.5, 0.8, 0.4, 0.3,
    0.5, 0.7, 0.6, 0.4, 0.5, 0.8, 0.9, 0.5, 0.4, 0.3
  ];

  _WaveformPainter({
    required this.progress,
    required this.waveColor,
    required this.activeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final barCount = _waveformHeights.length;
    final totalSpacing = size.width * 0.2; // 20% of width for spacing
    final barWidth = (size.width - totalSpacing) / barCount;
    final spacing = totalSpacing / (barCount - 1);

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < barCount; i++) {
      final barHeight = _waveformHeights[i] * size.height;
      final x = i * (barWidth + spacing);
      final y = (size.height - barHeight) / 2;

      final isPast = (x / size.width) <= progress;
      paint.color = isPast ? activeColor : waveColor;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, barHeight),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.waveColor != waveColor ||
        oldDelegate.activeColor != activeColor;
  }
}
