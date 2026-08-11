import 'dart:async';
import 'dart:typed_data';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/protocol/protocol_codec.dart';
import 'package:vantra/core/protocol/protocol_exception.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/utils/logger.dart';

class SessionSecureIdentity {
  final String endpointId;
  final int protocolVersion;
  final String peerId;
  final String displayName;
  final Uint8List identityPublicKey;
  final Uint8List ephemeralPublicKey;
  final Uint8List signature;
  final int? minSupportedVersion;
  final int? maxSupportedVersion;
  final List<VantraCapability>? supportedCapabilities;

  const SessionSecureIdentity({
    required this.endpointId,
    required this.protocolVersion,
    required this.peerId,
    required this.displayName,
    required this.identityPublicKey,
    required this.ephemeralPublicKey,
    required this.signature,
    this.minSupportedVersion,
    this.maxSupportedVersion,
    this.supportedCapabilities,
  });

  String get identityPublicKeyHex => identityPublicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  String get ephemeralPublicKeyHex => ephemeralPublicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  String get signatureHex => signature.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class EncryptedMessageEvent {
  final String endpointId;
  final int protocolVersion;
  final String messageId;
  final String sessionId;
  final int sequence;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;

  const EncryptedMessageEvent({
    required this.endpointId,
    required this.protocolVersion,
    required this.messageId,
    required this.sessionId,
    required this.sequence,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  String get nonceHex => nonce.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  String get ciphertextHex => ciphertext.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  String get macHex => mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class MessagingService {
  final Transport _transport;
  final ProtocolCodec codec;
  late final StreamSubscription _payloadSubscription;

  final _encryptedMessageController = StreamController<EncryptedMessageEvent>.broadcast();
  final _secureIdentityController = StreamController<SessionSecureIdentity>.broadcast();

  Stream<EncryptedMessageEvent> get encryptedMessageStream => _encryptedMessageController.stream;
  Stream<SessionSecureIdentity> get secureIdentityStream => _secureIdentityController.stream;

  MessagingService(this._transport, {this.codec = const ProtobufCodec()}) {
    _payloadSubscription = _transport.payloadReceivedStream.listen(_onPayloadReceived);
  }

  void dispose() {
    _payloadSubscription.cancel();
    _encryptedMessageController.close();
    _secureIdentityController.close();
  }

  /// Sends a secure identity handshake protobuf packet
  Future<void> sendSecureIdentity({
    required String endpointId,
    required String peerId,
    required String displayName,
    required Uint8List identityPublicKey,
    required Uint8List ephemeralPublicKey,
    required Uint8List signature,
    int protocolVersion = kCurrentProtocolVersion,
    int? minSupportedVersion,
    int? maxSupportedVersion,
    List<VantraCapability>? supportedCapabilities,
  }) async {
    VantraLogger.log('[VANTRA][SECURITY] Transmitting IDENTITY_SECURE protobuf packet to $endpointId');
    final envelope = DomainHandshakePayload(
      protocolVersion: protocolVersion,
      peerId: peerId,
      displayName: displayName,
      identityPublicKey: identityPublicKey,
      ephemeralPublicKey: ephemeralPublicKey,
      signature: signature,
      minSupportedVersion: minSupportedVersion,
      maxSupportedVersion: maxSupportedVersion,
      supportedCapabilities: supportedCapabilities,
    );
    final bytes = codec.encodeWireEnvelope(envelope);
    await _transport.send(endpointId, bytes);
  }

  /// Transmits an encrypted message protobuf packet
  Future<void> sendEncryptedMessage({
    required String endpointId,
    required String messageId,
    required String sessionId,
    required int sequence,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List mac,
    int protocolVersion = kCurrentProtocolVersion,
  }) async {
    final envelope = DomainEncryptedEnvelope(
      protocolVersion: protocolVersion,
      messageId: messageId,
      sessionId: sessionId,
      sequence: sequence,
      nonce: nonce,
      ciphertext: ciphertext,
      mac: mac,
    );
    VantraLogger.log('[VANTRA][PROTO] ENCRYPTED ENVELOPE BUILT messageId=$messageId sessionIdPresent=true sequence=$sequence');

    final bytes = codec.encodeWireEnvelope(envelope);
    VantraLogger.log('[VANTRA][PROTO] WIRE ENCODE SUCCESS messageId=$messageId wireByteLength=${bytes.length}');

    VantraLogger.log('[VANTRA][TRANSPORT] SEND INVOKED endpointId=$endpointId messageId=$messageId byteLength=${bytes.length}');
    try {
      await _transport.send(endpointId, bytes);
      VantraLogger.log('[VANTRA][TRANSPORT] SEND SUCCESS endpointId=$endpointId messageId=$messageId');
    } catch (e) {
      VantraLogger.log('[VANTRA][TRANSPORT] SEND FAILED endpointId=$endpointId messageId=$messageId errorType=${e.runtimeType}');
      rethrow;
    }
  }

  void _onPayloadReceived(PayloadReceivedEvent event) {
    VantraLogger.log('[VANTRA][MESSAGE] Wire payload received from ${event.endpointId} (${event.bytes.length} bytes)');
    VantraLogger.log('[VANTRA][PROTO] WIRE DECODE START byteLength=${event.bytes.length}');
    DomainWireEnvelope envelope;
    try {
      envelope = codec.decodeWireEnvelope(event.bytes);
      if (envelope is DomainEncryptedEnvelope) {
        VantraLogger.log('[VANTRA][PROTO] WIRE DECODE SUCCESS payloadType=ENCRYPTED_MESSAGE messageId=${envelope.messageId} sequence=${envelope.sequence}');
      } else {
        VantraLogger.log('[VANTRA][PROTO] WIRE DECODE SUCCESS payloadType=${envelope.runtimeType} messageId=none sequence=0');
      }
    } catch (e) {
      VantraLogger.log('[VANTRA][PROTO] WIRE DECODE FAILED errorType=${e.runtimeType}');
      rethrow;
    }
    try {

      switch (envelope) {
        case DomainHandshakePayload handshake:
          VantraLogger.log('[VANTRA][SECURITY] IDENTITY_SECURE protobuf received for peer ${handshake.peerId}');
          _secureIdentityController.add(SessionSecureIdentity(
            endpointId: event.endpointId,
            protocolVersion: handshake.protocolVersion,
            peerId: handshake.peerId,
            displayName: handshake.displayName,
            identityPublicKey: handshake.identityPublicKey,
            ephemeralPublicKey: handshake.ephemeralPublicKey,
            signature: handshake.signature,
            minSupportedVersion: handshake.minSupportedVersion,
            maxSupportedVersion: handshake.maxSupportedVersion,
            supportedCapabilities: handshake.supportedCapabilities,
          ));

        case DomainEncryptedEnvelope enc:
          VantraLogger.log('[VANTRA][SECURITY] ENCRYPTED_TEXT protobuf packet received for message ${enc.messageId}');
          _encryptedMessageController.add(EncryptedMessageEvent(
            endpointId: event.endpointId,
            protocolVersion: enc.protocolVersion,
            messageId: enc.messageId,
            sessionId: enc.sessionId,
            sequence: enc.sequence,
            nonce: enc.nonce,
            ciphertext: enc.ciphertext,
            mac: enc.mac,
          ));

        case DomainProtocolError err:
          VantraLogger.log('[VANTRA][SECURITY] Outer PROTOCOL_ERROR packet received (unauthenticated): code=${err.errorCode}, message=${err.errorMessage}');
      }
    } on ProtocolValidationException catch (e) {
      VantraLogger.log('[VANTRA][SECURITY] Protocol validation rejected payload from ${event.endpointId}: ${e.message}');
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] Malformed wire payload from ${event.endpointId}, discarded: $e', e, stack);
    }
  }
}
