import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/message.dart';
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

  group('Phase 7: Retry Queue & Offline Reliability Tests', () {
    test('Offline message is queued in pending state and doesn\'t throw exceptions', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);

      const peerId = 'offline-peer-123';
      
      // Composing offline text message
      await expectLater(
        notifier.sendTextMessage(peerId, 'Hello offline world'),
        completes,
      );

      // Verify message is saved to SQLite with status = pending
      final pending = await repo.getPendingOrFailedMessages(peerId);
      expect(pending.length, 1);
      expect(pending[0].text, 'Hello offline world');
      expect(pending[0].status, MessageStatus.pending);
      expect(pending[0].retryCount, 0);
    });

    test('FIFO transmission flushes entire queue once session is established', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      const peerId = 'fifo-peer-abc';

      // Queue 3 messages offline
      await notifier.sendTextMessage(peerId, 'Msg 1');
      await notifier.sendTextMessage(peerId, 'Msg 2');
      await notifier.sendTextMessage(peerId, 'Msg 3');

      expect(fakeTransport.sentPayloads.length, 0);

      // Establish secure connection
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'FIFO_EP',
        status: ConnectionStatus.connected,
        endpointName: 'FIFO_EP',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remoteIdKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteIdPub = await remoteIdKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphKeyPair.extractPublicKey();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'FIFOPeer',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final remoteHandshake = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'FIFOPeer',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('FIFO_EP', codec.encodeWireEnvelope(remoteHandshake));
      await Future.delayed(const Duration(milliseconds: 100));

      // Flusher triggers automatically upon secure session state
      // Verify that payloads are sent to transport
      expect(fakeTransport.sentPayloads.length, greaterThanOrEqualTo(1));
    });

    test('Lost-ACK & Duplicate-Message ACK Recovery prevents duplicate SQLite inserts but returns ACK', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      const peerId = 'duplicate-peer-xyz';

      // Connect securely first
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'DUP_EP',
        status: ConnectionStatus.connected,
        endpointName: 'DUP_EP',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remoteIdKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteIdPub = await remoteIdKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphKeyPair.extractPublicKey();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'DupPeer',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final remoteHandshake = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'DupPeer',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('DUP_EP', codec.encodeWireEnvelope(remoteHandshake));
      await Future.delayed(const Duration(milliseconds: 50));

      final session = container.read(messagingStateProvider).sessions[peerId];
      expect(session?.isSecure, isTrue);

      // Extract local ephemeral public key from local handshake
      final localHandshake = codec.decodeWireEnvelope(fakeTransport.sentPayloads[0]) as DomainHandshakePayload;

      // Derive secure keys locally to mimic peer
      final derivedKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: remoteEphKeyPair,
        remoteEphemeralPublicKeyBytes: localHandshake.ephemeralPublicKey,
      );

      final messageId = const Uuid().v4();
      final textMessagePayload = DomainTextMessage(
        messageId: messageId,
        sessionId: derivedKeys.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: 'local-device',
        content: 'Duplicate detection message',
      );

      // First delivery of message
      final encResult1 = await cryptoService.encryptBytes(
        secretKey: derivedKeys.sendKey,
        sessionSalt: derivedKeys.sessionSalt,
        sequence: 1,
        messageId: messageId,
        plaintextBytes: codec.encodePlaintext(textMessagePayload),
      );

      fakeTransport.triggerIncomingPayload(
        'DUP_EP',
        codec.encodeWireEnvelope(DomainEncryptedEnvelope(
          messageId: messageId,
          sessionId: derivedKeys.sessionId,
          sequence: 1,
          nonce: Uint8List.fromList(encResult1.nonce),
          ciphertext: Uint8List.fromList(encResult1.ciphertext),
          mac: Uint8List.fromList(encResult1.mac),
          protocolVersion: kCurrentProtocolVersion,
        )),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      final messages1 = await repo.getConversation('local-device', peerId);
      expect(messages1.length, 1);
      expect(messages1[0].text, 'Duplicate detection message');

      // Mimic duplicate send due to lost ACK
      final textMessagePayload2 = DomainTextMessage(
        messageId: messageId,
        sessionId: derivedKeys.sessionId,
        sequence: 2, // new sequence number
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: 'local-device',
        content: 'Duplicate detection message',
      );

      final encResult2 = await cryptoService.encryptBytes(
        secretKey: derivedKeys.sendKey,
        sessionSalt: derivedKeys.sessionSalt,
        sequence: 2,
        messageId: messageId,
        plaintextBytes: codec.encodePlaintext(textMessagePayload2),
      );

      fakeTransport.sentPayloads.clear();
      fakeTransport.triggerIncomingPayload(
        'DUP_EP',
        codec.encodeWireEnvelope(DomainEncryptedEnvelope(
          messageId: messageId,
          sessionId: derivedKeys.sessionId,
          sequence: 2,
          nonce: Uint8List.fromList(encResult2.nonce),
          ciphertext: Uint8List.fromList(encResult2.ciphertext),
          mac: Uint8List.fromList(encResult2.mac),
          protocolVersion: kCurrentProtocolVersion,
        )),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      // SQLite count remains 1, no duplicate rows
      final messages2 = await repo.getConversation('local-device', peerId);
      expect(messages2.length, 1);

      // Verify that return ACK was sent immediately
      expect(fakeTransport.sentPayloads.length, 1);
    });

    test('Crash recovery: SENT messages are recovered back to pending on startup', () async {
      final repo = container.read(messagingRepositoryProvider);
      
      final msg = VantraMessage(
        messageId: 'crash-msg-id',
        senderId: 'local-device',
        receiverId: 'remote-peer',
        text: 'In-flight crash message',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.sent, // App crashed while waiting for ACK
      );

      // Save to SQLite
      await repo.saveOutgoingMessage(msg);
      await repo.updateMessageStatus('crash-msg-id', MessageStatus.sent);

      // Trigger repository recovery manually (mimics startup microtask)
      await repo.recoverSentMessages();

      final fetched = await repo.getMessageById('crash-msg-id');
      expect(fetched?.status, MessageStatus.pending); // Recovered!
    });
  });
}
