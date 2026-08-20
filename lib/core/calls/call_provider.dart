import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/calls/call_session.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/utils/logger.dart';

final callStateProvider = NotifierProvider<CallNotifier, CallSession?>(() {
  return CallNotifier();
});

class CallNotifier extends Notifier<CallSession?> {
  Timer? _ringingTimer;
  Timer? _durationTimer;

  @override
  CallSession? build() {
    ref.onDispose(() {
      _ringingTimer?.cancel();
      _durationTimer?.cancel();
    });
    return null;
  }
  
  // Initiates an outgoing call
  Future<void> initiateCall(String peerId) async {
    if (state != null) {
      VantraLogger.log('[VANTRA][CALL] Cannot initiate call: another session is active.');
      return;
    }
    
    final callId = const Uuid().v4();
    final session = CallSession(
      callId: callId,
      peerId: peerId,
      status: CallStatus.outgoing,
    );
    state = session;

    _startRingingTimeout();
    _sendSignaling(peerId, callId, DomainMediaControlType.offer);
  }

  // Incoming call offer received
  void handleIncomingOffer(String peerId, String callId) {
    if (state != null) {
      VantraLogger.log('[VANTRA][CALL] Busy: rejecting incoming call offer callId=$callId from peerId=$peerId');
      _sendSignaling(peerId, callId, DomainMediaControlType.reject, isBusy: true);
      return;
    }

    state = CallSession(
      callId: callId,
      peerId: peerId,
      status: CallStatus.incoming,
    );
    _startRingingTimeout();
  }

  // Answer call (called by receiver)
  void answerCall() {
    final current = state;
    if (current == null || current.status != CallStatus.incoming) return;

    _ringingTimer?.cancel();
    state = current.copyWith(
      status: CallStatus.active,
      startedAt: DateTime.now(),
    );

    _sendSignaling(current.peerId, current.callId, DomainMediaControlType.accept);
    _startDurationTimer();
  }

  // Decline call (called by receiver when ringing)
  void declineCall() {
    final current = state;
    if (current == null || current.status != CallStatus.incoming) return;

    _ringingTimer?.cancel();
    state = null;
    _sendSignaling(current.peerId, current.callId, DomainMediaControlType.reject);
  }

  // End active call or cancel outgoing call
  void endCall() {
    final current = state;
    if (current == null) return;

    _ringingTimer?.cancel();
    _durationTimer?.cancel();

    state = current.copyWith(status: CallStatus.ended);

    _sendSignaling(current.peerId, current.callId, DomainMediaControlType.cancel);

    Future.delayed(const Duration(seconds: 1), () {
      if (state?.callId == current.callId) {
        state = null;
      }
    });
  }

  // Handle peer accepting our call
  void handleIncomingAccept(String callId) {
    final current = state;
    if (current == null || current.callId != callId || current.status != CallStatus.outgoing) return;

    _ringingTimer?.cancel();
    state = current.copyWith(
      status: CallStatus.active,
      startedAt: DateTime.now(),
    );
    _startDurationTimer();
  }

  // Handle peer rejecting/ending/declining our call
  void handleIncomingReject(String callId) {
    final current = state;
    if (current == null || current.callId != callId) return;

    _ringingTimer?.cancel();
    _durationTimer?.cancel();
    state = current.copyWith(status: CallStatus.ended, error: 'Call busy or declined');

    Future.delayed(const Duration(seconds: 1), () {
      if (state?.callId == callId) {
        state = null;
      }
    });
  }

  void handleIncomingCancel(String callId) {
    final current = state;
    if (current == null || current.callId != callId) return;

    _ringingTimer?.cancel();
    _durationTimer?.cancel();
    state = current.copyWith(status: CallStatus.ended);

    Future.delayed(const Duration(seconds: 1), () {
      if (state?.callId == callId) {
        state = null;
      }
    });
  }

  void toggleMute() {
    final current = state;
    if (current != null) {
      state = current.copyWith(isMuted: !current.isMuted);
    }
  }

  void toggleSpeaker() {
    final current = state;
    if (current != null) {
      state = current.copyWith(isSpeaker: !current.isSpeaker);
    }
  }

  // Audio frame streaming receiver
  void handleIncomingAudioFrame(String callId, int frameIndex, Uint8List audioData) {
    final current = state;
    if (current == null || current.callId != callId || current.status != CallStatus.active) return;
    
    if (current.isMuted) return;

    // Log audio frame reception in debug mode
    VantraLogger.log('[VANTRA][CALL] Received audio frame index=$frameIndex size=${audioData.length}');
  }

  // Audio frame streaming sender
  void sendAudioFrame(Uint8List frameData, int frameIndex) {
    final current = state;
    if (current == null || current.status != CallStatus.active) return;

    final messagingNotifier = ref.read(messagingStateProvider.notifier);
    final msgId = const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final senderId = ref.read(localIdentityStateProvider).peerId;

    final audioChunk = DomainMediaChunk(
      messageId: msgId,
      sessionId: current.callId,
      sequence: frameIndex + 1,
      timestampMs: timestamp,
      senderId: senderId,
      receiverId: current.peerId,
      transferId: current.callId,
      chunkIndex: frameIndex,
      totalChunks: -1,
      data: frameData,
    );

    messagingNotifier.sendCallPlaintext(current.peerId, audioChunk);
  }

  void _sendSignaling(String peerId, String callId, DomainMediaControlType type, {bool isBusy = false}) {
    final messagingNotifier = ref.read(messagingStateProvider.notifier);
    final msgId = const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final senderId = ref.read(localIdentityStateProvider).peerId;

    final signal = DomainMediaControl(
      messageId: msgId,
      sessionId: callId,
      sequence: 1,
      timestampMs: timestamp,
      senderId: senderId,
      receiverId: peerId,
      type: type,
      transferId: callId,
      mimeType: 'audio/call',
      fileName: isBusy ? 'busy' : null,
    );

    messagingNotifier.sendCallPlaintext(peerId, signal);
  }

  void _startRingingTimeout() {
    _ringingTimer?.cancel();
    _ringingTimer = Timer(const Duration(seconds: 30), () {
      VantraLogger.log('[VANTRA][CALL] Ringing timeout reached.');
      endCall();
    });
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final current = state;
      if (current != null && current.status == CallStatus.active) {
        state = current.copyWith(
          duration: current.duration + const Duration(seconds: 1),
        );
      }
    });
  }
}
