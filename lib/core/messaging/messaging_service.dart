import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/utils/logger.dart';

class SessionSecureIdentity {
  final String endpointId;
  final int protocolVersion;
  final String peerId;
  final String displayName;
  final String identityPublicKeyHex;
  final String ephemeralPublicKeyHex;
  final String signatureHex;

  const SessionSecureIdentity({
    required this.endpointId,
    required this.protocolVersion,
    required this.peerId,
    required this.displayName,
    required this.identityPublicKeyHex,
    required this.ephemeralPublicKeyHex,
    required this.signatureHex,
  });
}

class EncryptedMessageEvent {
  final String endpointId;
  final int protocolVersion;
  final String messageId;
  final String nonceHex;
  final String ciphertextHex;
  final String macHex;

  const EncryptedMessageEvent({
    required this.endpointId,
    required this.protocolVersion,
    required this.messageId,
    required this.nonceHex,
    required this.ciphertextHex,
    required this.macHex,
  });
}

class MessagingService {
  final Transport _transport;
  late final StreamSubscription _payloadSubscription;

  final _encryptedMessageController = StreamController<EncryptedMessageEvent>.broadcast();
  final _secureIdentityController = StreamController<SessionSecureIdentity>.broadcast();

  Stream<EncryptedMessageEvent> get encryptedMessageStream => _encryptedMessageController.stream;
  Stream<SessionSecureIdentity> get secureIdentityStream => _secureIdentityController.stream;

  MessagingService(this._transport) {
    _payloadSubscription = _transport.payloadReceivedStream.listen(_onPayloadReceived);
  }

  void dispose() {
    _payloadSubscription.cancel();
    _encryptedMessageController.close();
    _secureIdentityController.close();
  }

  /// Sends a secure identity handshake packet
  Future<void> sendSecureIdentity({
    required String endpointId,
    required String peerId,
    required String displayName,
    required String identityPublicKeyHex,
    required String ephemeralPublicKeyHex,
    required String signatureHex,
    int protocolVersion = 1,
  }) async {
    VantraLogger.log('[VANTRA][SECURITY] Transmitting IDENTITY_SECURE packet to $endpointId');
    final payload = {
      'type': 'IDENTITY_SECURE',
      'v': protocolVersion,
      'peerId': peerId,
      'displayName': displayName,
      'identityPublicKey': identityPublicKeyHex,
      'ephemeralPublicKey': ephemeralPublicKeyHex,
      'signature': signatureHex,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    await _transport.send(endpointId, bytes);
  }

  /// Transmits an encrypted message packet
  Future<void> sendEncryptedMessage({
    required String endpointId,
    required String messageId,
    required String nonceHex,
    required String ciphertextHex,
    required String macHex,
    int protocolVersion = 1,
  }) async {
    VantraLogger.log('[VANTRA][SECURITY] Transmitting ENCRYPTED_TEXT packet for $messageId to $endpointId');
    final payload = {
      'type': 'ENCRYPTED_TEXT',
      'v': protocolVersion,
      'messageId': messageId,
      'nonce': nonceHex,
      'ciphertext': ciphertextHex,
      'mac': macHex,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    await _transport.send(endpointId, bytes);
  }

  void _onPayloadReceived(PayloadReceivedEvent event) {
    VantraLogger.log('[VANTRA][MESSAGE] Payload received from ${event.endpointId}');
    try {
      final json = jsonDecode(utf8.decode(event.bytes)) as Map<String, dynamic>;
      final type = json['type'] as String?;
      final version = json['v'] as int? ?? 0;

      // Strict protocol downgrade rejection: reject any message with v < 1
      if (version < 1) {
        VantraLogger.log('[VANTRA][SECURITY] Rejected insecure or legacy payload (version $version) from ${event.endpointId}');
        return;
      }

      if (type == 'IDENTITY_SECURE') {
        final peerId = json['peerId'] as String;
        final displayName = json['displayName'] as String;
        final idKey = json['identityPublicKey'] as String;
        final ephKey = json['ephemeralPublicKey'] as String;
        final sig = json['signature'] as String;

        VantraLogger.log('[VANTRA][SECURITY] IDENTITY_SECURE received for peer $peerId');
        _secureIdentityController.add(SessionSecureIdentity(
          endpointId: event.endpointId,
          protocolVersion: version,
          peerId: peerId,
          displayName: displayName,
          identityPublicKeyHex: idKey,
          ephemeralPublicKeyHex: ephKey,
          signatureHex: sig,
        ));
      } else if (type == 'ENCRYPTED_TEXT') {
        final messageId = json['messageId'] as String;
        final nonce = json['nonce'] as String;
        final ciphertext = json['ciphertext'] as String;
        final mac = json['mac'] as String;

        VantraLogger.log('[VANTRA][SECURITY] ENCRYPTED_TEXT packet received for message $messageId');
        _encryptedMessageController.add(EncryptedMessageEvent(
          endpointId: event.endpointId,
          protocolVersion: version,
          messageId: messageId,
          nonceHex: nonce,
          ciphertextHex: ciphertext,
          macHex: mac,
        ));
      } else {
        VantraLogger.log('[VANTRA][SECURITY] Rejected unknown payload type: $type');
      }
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][MESSAGE] Malformed payload received, discarded', e, stack);
    }
  }
}
