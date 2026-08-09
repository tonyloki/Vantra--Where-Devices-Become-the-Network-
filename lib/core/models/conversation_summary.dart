import 'message_status.dart';
import 'peer_trust_state.dart';

class ConversationSummary {
  final String peerId;
  final String displayName;
  final String? nickname;
  final String? fingerprint;
  final PeerTrustState trustState;
  final String lastMessageText;
  final int lastMessageTimestamp;
  final MessageStatus lastMessageStatus;
  final bool isOutgoing;
  final int unreadCount;
  final bool isOnline;
  final bool isSecure;

  const ConversationSummary({
    required this.peerId,
    required this.displayName,
    this.nickname,
    this.fingerprint,
    this.trustState = PeerTrustState.untrusted,
    required this.lastMessageText,
    required this.lastMessageTimestamp,
    required this.lastMessageStatus,
    required this.isOutgoing,
    required this.unreadCount,
    this.isOnline = false,
    this.isSecure = false,
  });

  String get effectiveName {
    if (nickname != null && nickname!.trim().isNotEmpty) {
      return nickname!.trim();
    }
    return displayName;
  }

  bool get isBlocked => trustState == PeerTrustState.distrusted;
  bool get isTrusted => trustState == PeerTrustState.trusted;
}
