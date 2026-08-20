import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

class VoiceRecorderWidget extends StatefulWidget {
  final Function(String filePath, int durationMs) onRecordComplete;
  final VoidCallback? onRecordingStarted;
  final VoidCallback? onRecordingCancelled;

  const VoiceRecorderWidget({
    super.key,
    required this.onRecordComplete,
    this.onRecordingStarted,
    this.onRecordingCancelled,
  });

  @override
  State<VoiceRecorderWidget> createState() => _VoiceRecorderWidgetState();
}

class _VoiceRecorderWidgetState extends State<VoiceRecorderWidget> with SingleTickerProviderStateMixin {
  late final AudioRecorder _audioRecorder;
  bool _isRecording = false;
  int _seconds = 0;
  Timer? _timer;
  String? _tempPath;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _audioRecorder.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final fileName = 'voice_${const Uuid().v4()}.aac';
        _tempPath = path.join(tempDir.path, fileName);

        widget.onRecordingStarted?.call();

        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            sampleRate: 44100,
            bitRate: 128000,
          ),
          path: _tempPath!,
        );

        setState(() {
          _isRecording = true;
          _seconds = 0;
        });

        _pulseController.repeat(reverse: true);

        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          setState(() {
            _seconds++;
          });
        });
      }
    } catch (e) {
      debugPrint('Error starting record: $e');
    }
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    _timer?.cancel();
    _timer = null;

    try {
      final path = await _audioRecorder.stop();
      setState(() {
        _isRecording = false;
      });

      _pulseController.stop();
      if (cancel) {
        if (path != null) {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        }
        widget.onRecordingCancelled?.call();
      } else {
        if (path != null && _seconds > 0) {
          widget.onRecordComplete(path, _seconds * 1000);
        }
      }
    } catch (e) {
      debugPrint('Error stopping record: $e');
    }
  }

  String _formatDuration(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (!_isRecording) {
      return IconButton(
        icon: const Icon(Icons.mic_none, color: Colors.tealAccent, size: 28),
        onPressed: _startRecording,
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[900]?.withOpacity(0.95),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.tealAccent.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withOpacity(0.3 + (_pulseController.value * 0.7)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withOpacity(0.2),
                      blurRadius: 4 + (_pulseController.value * 6),
                      spreadRadius: 1 + (_pulseController.value * 3),
                    )
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 12),
          Text(
            _formatDuration(_seconds),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ShaderMask(
              shaderCallback: (rect) {
                return LinearGradient(
                  colors: [Colors.white, Colors.white.withOpacity(0.2)],
                  stops: const [0.6, 1.0],
                ).createShader(rect);
              },
              child: const Text(
                'Recording voice message...',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _stopRecording(cancel: true),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _stopRecording(cancel: false),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.tealAccent,
              ),
              child: const Icon(Icons.send, color: Colors.black, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}
