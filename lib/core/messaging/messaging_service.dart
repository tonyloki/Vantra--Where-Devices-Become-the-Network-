import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/identity/local_identity.dart';
import 'package:vantra/core/utils/logger.dart';
import 'message.dart';

class SessionIdentity {
  final String endpointId;
  final String peerId;
  final String displayName;

  const SessionIdentity({
    required this.endpointId,
    required this.peerId,
    required this.displayName,
  });
}

class MessagingService {
  final Transport _transport;
  late final StreamSubscription _payloadSubscription;

  final _messageController = StreamController<VantraMessage>.broadcast();
  final _identityController = StreamController<SessionIdentity>.broadcast();

  Stream<VantraMessage> get messageStream => _messageController.stream;
  Stream<SessionIdentity> get identityStream => _identityController.stream;

  MessagingService(this._transport) {
    _payloadSubscription = _transport.payloadReceivedStream.listen(_onPayloadReceived);
  }

  void dispose() {
    _payloadSubscription.cancel();
    _messageController.close();
    _identityController.close();
  }

  Future<void> sendIdentity(String endpointId, LocalIdentity localIdentity) async {
    VantraLogger.log('[VANTRA][MESSAGE] Sending IDENTITY handshake to $endpointId: ${localIdentity.displayName}');
    final payload = {
      'type': 'IDENTITY',
      'peerId': localIdentity.peerId,
      'displayName': localIdentity.displayName,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    await _transport.send(endpointId, bytes);
  }

  Future<VantraMessage> sendTextMessage(
    String endpointId,
    String senderId,
    String receiverId,
    String text, {
    String? messageId,
    int? timestamp,
  }) async {
    VantraLogger.log('[VANTRA][MESSAGE] Creating TEXT message for $endpointId');
    final message = VantraMessage(
      messageId: messageId ?? const Uuid().v4(),
      senderId: senderId,
      receiverId: receiverId,
      text: text,
      timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch,
    );

    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message.toJson())));
    VantraLogger.log('[VANTRA][MESSAGE] Sending payload to $endpointId');
    await _transport.send(endpointId, bytes);
    VantraLogger.log('[VANTRA][MESSAGE] Message sent to $endpointId');
    return message;
  }

  void _onPayloadReceived(PayloadReceivedEvent event) {
    VantraLogger.log('[VANTRA][MESSAGE] Payload received from ${event.endpointId}');
    try {
      final json = jsonDecode(utf8.decode(event.bytes)) as Map<String, dynamic>;
      final type = json['type'] as String?;
      if (type == 'IDENTITY') {
        final peerId = json['peerId'] as String;
        final displayName = json['displayName'] as String;
        VantraLogger.log('[VANTRA][MESSAGE] Handshake identity decoded: $peerId ($displayName)');
        _identityController.add(SessionIdentity(
          endpointId: event.endpointId,
          peerId: peerId,
          displayName: displayName,
        ));
      } else if (type == 'TEXT') {
        final message = VantraMessage.fromJson(json);
        VantraLogger.log('[VANTRA][MESSAGE] Message decoded: ${message.messageId}');
        _messageController.add(message);
      } else {
        VantraLogger.log('[VANTRA][MESSAGE] Invalid payload: Unknown type $type');
      }
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][MESSAGE] Invalid payload: Failed to decode JSON', e, stack);
    }
  }
}
