import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport fakeTransport;
  late ProviderContainer container;
  late AppDatabase testDb;
  late CryptoService cryptoService;
  const codec = ProtobufCodec();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    fakeTransport = FakeTransport();
    testDb = AppDatabase.forTesting(NativeDatabase.memory());
    cryptoService = CryptoService();

    final fakeSecureStorage = FakeSecureStorageService();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        transportProvider.overrideWithValue(fakeTransport),
        appDatabaseProvider.overrideWithValue(testDb),
        secureStorageServiceProvider.overrideWithValue(fakeSecureStorage),
      ],
    );

    await container.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
  });

  tearDown(() async {
    await testDb.close();
    container.dispose();
  });

  group('Encrypted Protobuf Messaging Pipeline, Replay & ACK Tests', () {
    test('End-to-end encrypted sending, receiving, replay protection, and encrypted ACK delivery', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // 1. Establish handshake using Protobuf wire
      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
      final remotePeerId = const Uuid().v4();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: remotePeerId,
        displayName: 'RemoteSecurePeer',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final handshakePayload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: remotePeerId,
        displayName: 'RemoteSecurePeer',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      // 2. Send outgoing encrypted message
      await notifier.sendTextMessage(remotePeerId, 'Secret payload from local');

      // Verify payload sent over transport is protobuf encrypted envelope
      expect(fakeTransport.sentPayloads.length, 2);
      final sentEnvelope = codec.decodeWireEnvelope(fakeTransport.sentPayloads[1]);
      expect(sentEnvelope, isA<DomainEncryptedEnvelope>());
      final sentEnc = sentEnvelope as DomainEncryptedEnvelope;
      expect(sentEnc.protocolVersion, kCurrentProtocolVersion);
      expect(sentEnc.ciphertext.isNotEmpty, isTrue);

      // Verify stored locally as sent
      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      var conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv.length, 1);
      expect(conv[0].text, 'Secret payload from local');
      expect(conv[0].status, MessageStatus.sent);
      final localSentMsgId = conv[0].messageId;

      // Extract local ephemeral public key from sent handshake
      final localHandshake = codec.decodeWireEnvelope(fakeTransport.sentPayloads[0]) as DomainHandshakePayload;
      final remoteDerivedKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: remoteEphemeralKeyPair,
        remoteEphemeralPublicKeyBytes: localHandshake.ephemeralPublicKey,
      );

      // 3. Receive incoming encrypted message from remote peer
      final incomingMessageId = const Uuid().v4();
      final remotePlaintext = DomainTextMessage(
        messageId: incomingMessageId,
        sessionId: remoteDerivedKeys.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: remotePeerId,
        receiverId: localIdentity.peerId,
        content: 'Reply secret from remote',
      );

      final encResult = await cryptoService.encryptBytes(
        secretKey: remoteDerivedKeys.sendKey,
        sessionSalt: remoteDerivedKeys.sessionSalt,
        sequence: 1,
        messageId: incomingMessageId,
        plaintextBytes: codec.encodePlaintext(remotePlaintext),
      );

      final encWireEnvelope = DomainEncryptedEnvelope(
        protocolVersion: kCurrentProtocolVersion,
        messageId: incomingMessageId,
        sessionId: remoteDerivedKeys.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encResult.nonce),
        ciphertext: Uint8List.fromList(encResult.ciphertext),
        mac: Uint8List.fromList(encResult.mac),
      );

      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(encWireEnvelope));
      await Future.delayed(const Duration(milliseconds: 50));

      // Verify decrypted and saved to SQLite as received
      conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv.length, 2);
      expect(conv[1].text, 'Reply secret from remote');
      expect(conv[1].status, MessageStatus.received);

      // Verify local node transmitted an encrypted ACK back
      expect(fakeTransport.sentPayloads.length, 3);
      final sentAckEnvelope = codec.decodeWireEnvelope(fakeTransport.sentPayloads[2]) as DomainEncryptedEnvelope;
      expect(sentAckEnvelope.messageId, isNot(equals(incomingMessageId))); // ACK unique ID invariant!

      // Decrypt ACK using remote keys
      final secSession = notifier.securitySessions[remotePeerId]!;
      final decryptedAckBytes = await cryptoService.decryptBytes(
        secretKey: secSession.getSendKeyForMessage(sentAckEnvelope.messageId),
        nonce: sentAckEnvelope.nonce,
        ciphertext: sentAckEnvelope.ciphertext,
        mac: sentAckEnvelope.mac,
        messageId: sentAckEnvelope.messageId,
      );
      final decryptedAck = codec.decodePlaintext(decryptedAckBytes) as DomainAckMessage;
      expect(decryptedAck.originalMessageId, incomingMessageId);
      expect(decryptedAck.status, DomainDeliveryStatus.delivered);

      // 4. Remote peer sends an encrypted ACK for local's initial sent message
      final ackFromRemoteId = const Uuid().v4();
      final remoteAckPlaintext = DomainAckMessage(
        messageId: ackFromRemoteId,
        sessionId: remoteDerivedKeys.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: remotePeerId,
        receiverId: localIdentity.peerId,
        originalMessageId: localSentMsgId,
        status: DomainDeliveryStatus.delivered,
      );

      final encRemoteAck = await cryptoService.encryptBytes(
        secretKey: remoteDerivedKeys.sendKey,
        sessionSalt: remoteDerivedKeys.sessionSalt,
        sequence: 2,
        messageId: ackFromRemoteId,
        plaintextBytes: codec.encodePlaintext(remoteAckPlaintext),
      );

      final remoteAckWireEnvelope = DomainEncryptedEnvelope(
        protocolVersion: kCurrentProtocolVersion,
        messageId: ackFromRemoteId,
        sessionId: remoteDerivedKeys.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encRemoteAck.nonce),
        ciphertext: Uint8List.fromList(encRemoteAck.ciphertext),
        mac: Uint8List.fromList(encRemoteAck.mac),
      );

      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(remoteAckWireEnvelope));
      await Future.delayed(const Duration(milliseconds: 50));

      // Verify local sent message transitioned to DELIVERED status in SQLite!
      conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv[0].status, MessageStatus.delivered);

      // 5. Replay attack test: transmit same packet again
      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(encWireEnvelope));
      await Future.delayed(const Duration(milliseconds: 50));

      // Must remain 2 messages (replay rejected)
      conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv.length, 2);
    });

    test('Bidirectional symmetry: local device decrypts remote messages whether it is Device A or Device B', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'PEER_X',
        status: ConnectionStatus.connected,
        endpointName: 'PEER_X',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
      final remotePeerId = const Uuid().v4();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: remotePeerId,
        displayName: 'PeerX',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final handshakePayload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: remotePeerId,
        displayName: 'PeerX',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('PEER_X', codec.encodeWireEnvelope(handshakePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final localHandshake = codec.decodeWireEnvelope(fakeTransport.sentPayloads[0]) as DomainHandshakePayload;
      final remoteDerivedKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: remoteEphemeralKeyPair,
        remoteEphemeralPublicKeyBytes: localHandshake.ephemeralPublicKey,
      );

      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      // Remote sends message to Local
      final incomingMessageId = const Uuid().v4();
      final remotePlaintext = DomainTextMessage(
        messageId: incomingMessageId,
        sessionId: remoteDerivedKeys.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: remotePeerId,
        receiverId: localIdentity.peerId,
        content: 'Bidirectional Protobuf Test Message',
      );

      final encResult = await cryptoService.encryptBytes(
        secretKey: remoteDerivedKeys.sendKey,
        sessionSalt: remoteDerivedKeys.sessionSalt,
        sequence: 1,
        messageId: incomingMessageId,
        plaintextBytes: codec.encodePlaintext(remotePlaintext),
      );

      final encWireEnvelope = DomainEncryptedEnvelope(
        protocolVersion: kCurrentProtocolVersion,
        messageId: incomingMessageId,
        sessionId: remoteDerivedKeys.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encResult.nonce),
        ciphertext: Uint8List.fromList(encResult.ciphertext),
        mac: Uint8List.fromList(encResult.mac),
      );

      fakeTransport.triggerIncomingPayload('PEER_X', codec.encodeWireEnvelope(encWireEnvelope));
      await Future.delayed(const Duration(milliseconds: 50));

      final conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv.length, 1);
      expect(conv[0].text, 'Bidirectional Protobuf Test Message');
      expect(conv[0].status, MessageStatus.received);
    });
  });
}
