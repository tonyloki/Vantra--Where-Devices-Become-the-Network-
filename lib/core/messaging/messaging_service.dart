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

class RoutedEnvelopeEvent {
  final String endpointId;
  final DomainRouteEnvelope envelope;
  const RoutedEnvelopeEvent({required this.endpointId, required this.envelope});
}

class RouteRequestEvent {
  final String endpointId;
  final DomainRouteRequest request;
  const RouteRequestEvent({required this.endpointId, required this.request});
}

class RouteReplyEvent {
  final String endpointId;
  final DomainRouteReply reply;
  const RouteReplyEvent({required this.endpointId, required this.reply});
}

class RouteErrorEvent {
  final String endpointId;
  final DomainRouteError error;
  const RouteErrorEvent({required this.endpointId, required this.error});
}

class MessagingService {
  final Transport _transport;
  final ProtocolCodec codec;
  late final StreamSubscription _payloadSubscription;

  final _encryptedMessageController = StreamController<EncryptedMessageEvent>.broadcast();
  final _secureIdentityController = StreamController<SessionSecureIdentity>.broadcast();
  final _routedEnvelopeController = StreamController<RoutedEnvelopeEvent>.broadcast();
  final _routeRequestController = StreamController<RouteRequestEvent>.broadcast();
  final _routeReplyController = StreamController<RouteReplyEvent>.broadcast();
  final _routeErrorController = StreamController<RouteErrorEvent>.broadcast();

  Stream<EncryptedMessageEvent> get encryptedMessageStream => _encryptedMessageController.stream;
  Stream<SessionSecureIdentity> get secureIdentityStream => _secureIdentityController.stream;
  Stream<RoutedEnvelopeEvent> get routedEnvelopeStream => _routedEnvelopeController.stream;
  Stream<RouteRequestEvent> get routeRequestStream => _routeRequestController.stream;
  Stream<RouteReplyEvent> get routeReplyStream => _routeReplyController.stream;
  Stream<RouteErrorEvent> get routeErrorStream => _routeErrorController.stream;

  MessagingService(this._transport, {this.codec = const ProtobufCodec()}) {
    _payloadSubscription = _transport.payloadReceivedStream.listen(_onPayloadReceived);
  }

  void dispose() {
    _payloadSubscription.cancel();
    _encryptedMessageController.close();
    _secureIdentityController.close();
    _routedEnvelopeController.close();
    _routeRequestController.close();
    _routeReplyController.close();
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
    print('[VANTRA][MESSAGE] TRANSPORT_SEND messageId=$messageId endpoint=$endpointId');
    try {
      await _transport.send(endpointId, bytes);
      print('[VANTRA][MESSAGE] TRANSPORT_SEND_SUCCESS messageId=$messageId');
      VantraLogger.log('[VANTRA][TRANSPORT] SEND SUCCESS endpointId=$endpointId messageId=$messageId');
    } catch (e) {
      VantraLogger.log('[VANTRA][TRANSPORT] SEND FAILED endpointId=$endpointId messageId=$messageId errorType=${e.runtimeType}');
      rethrow;
    }
  }

  /// Sends a RouteRequest packet over the transport
  Future<void> sendRouteRequest(String endpointId, DomainRouteRequest req) async {
    final bytes = codec.encodeWireEnvelope(req);
    await _transport.send(endpointId, bytes);
  }

  /// Sends a RouteReply packet over the transport
  Future<void> sendRouteReply(String endpointId, DomainRouteReply rep) async {
    final bytes = codec.encodeWireEnvelope(rep);
    await _transport.send(endpointId, bytes);
  }

  /// Sends a RouteEnvelope packet over the transport
  Future<void> sendRoutedEnvelope(String endpointId, DomainRouteEnvelope routed) async {
    final bytes = codec.encodeWireEnvelope(routed);
    await _transport.send(endpointId, bytes);
  }

  /// Sends a RouteError packet over the transport
  Future<void> sendRouteError(String endpointId, DomainRouteError err) async {
    final bytes = codec.encodeWireEnvelope(err);
    await _transport.send(endpointId, bytes);
  }


  void _onPayloadReceived(PayloadReceivedEvent event) {
    print('[VANTRA][MESSAGE] PAYLOAD_RECEIVED endpoint=${event.endpointId}');
    VantraLogger.log('[VANTRA][MESSAGE] Wire payload received from ${event.endpointId} (${event.bytes.length} bytes)');
    VantraLogger.log('[VANTRA][PROTO] WIRE DECODE START byteLength=${event.bytes.length}');
    try {
      final envelope = codec.decodeWireEnvelope(event.bytes);
      if (envelope is DomainEncryptedEnvelope) {
        VantraLogger.log('[VANTRA][PROTO] WIRE DECODE SUCCESS payloadType=ENCRYPTED_MESSAGE messageId=${envelope.messageId} sequence=${envelope.sequence}');
        print('[VANTRA][MESSAGE] ENVELOPE_DECODED messageId=${envelope.messageId}');
      } else {
        VantraLogger.log('[VANTRA][PROTO] WIRE DECODE SUCCESS payloadType=${envelope.runtimeType} messageId=none sequence=0');
        print('[VANTRA][MESSAGE] ENVELOPE_DECODED payloadType=${envelope.runtimeType}');
      }

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
          print('[VANTRA][MESSAGE] ENVELOPE_DECODED messageId=${enc.messageId}');
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

        case DomainRouteEnvelope routed:
          _routedEnvelopeController.add(RoutedEnvelopeEvent(
            endpointId: event.endpointId,
            envelope: routed,
          ));

        case DomainRouteRequest rreq:
          _routeRequestController.add(RouteRequestEvent(
            endpointId: event.endpointId,
            request: rreq,
          ));

        case DomainRouteReply rrep:
          _routeReplyController.add(RouteReplyEvent(
            endpointId: event.endpointId,
            reply: rrep,
          ));

        case DomainRouteError rerr:
          _routeErrorController.add(RouteErrorEvent(
            endpointId: event.endpointId,
            error: rerr,
          ));
      }
    } on ProtocolValidationException catch (e) {
      VantraLogger.log('[VANTRA][SECURITY] Protocol validation rejected payload from ${event.endpointId}: ${e.message}');
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] Malformed wire payload from ${event.endpointId}, discarded: $e', e, stack);
    }
  }
}
