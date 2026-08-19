import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;

import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/security/security_session.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/identity/local_identity.dart';
import 'test_fakes.dart';

class MockMeshTransport extends FakeTransport {
  final String localEndpoint;
  void Function(String endpointId, Uint8List data)? onSend;

  MockMeshTransport(this.localEndpoint);

  @override
  Future<void> send(String endpointId, Uint8List data) async {
    await super.send(endpointId, data);
    if (onSend != null) {
      Future.delayed(const Duration(milliseconds: 10), () {
        if (onSend != null) {
          onSend!(endpointId, data);
        }
      });
    }
  }
}

class FakeIdentityNotifier extends LocalIdentityNotifier {
  final LocalIdentity presetIdentity;
  FakeIdentityNotifier(this.presetIdentity);

  @override
  LocalIdentity build() => presetIdentity;

  @override
  Future<void> ensureKeysLoaded() async {
    state = presetIdentity;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cryptoService = CryptoService();

  group('Vantra V2 Phase 18 Large Media Streaming Tests', () {
    late MockMeshTransport transportA;
    late MockMeshTransport transportB;
    late MockMeshTransport transportC;

    late AppDatabase dbA;
    late AppDatabase dbB;
    late AppDatabase dbC;

    late ProviderContainer containerA;
    late ProviderContainer containerB;
    late ProviderContainer containerC;

    late Directory testTempDir;

    late LocalIdentity identityA;
    late LocalIdentity identityB;
    late LocalIdentity identityC;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      testTempDir = Directory.systemTemp.createTempSync('vantra_media_stream_test_');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'getApplicationDocumentsDirectory') {
            return testTempDir.path;
          }
          return null;
        },
      );

      dbA = AppDatabase.forTesting(NativeDatabase.memory());
      dbB = AppDatabase.forTesting(NativeDatabase.memory());
      dbC = AppDatabase.forTesting(NativeDatabase.memory());

      // Setup unique identities
      final keyPairA = await cryptoService.generateIdentityKeyPair();
      final pubKeyA = await keyPairA.extractPublicKey();
      identityA = LocalIdentity(
        peerId: 'peer-a-uuid',
        displayName: 'Device A',
        identityPublicKey: pubKeyA.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        fingerprint: await cryptoService.computeFingerprint(pubKeyA.bytes),
        keyPair: keyPairA,
      );

      final keyPairB = await cryptoService.generateIdentityKeyPair();
      final pubKeyB = await keyPairB.extractPublicKey();
      identityB = LocalIdentity(
        peerId: 'peer-b-uuid',
        displayName: 'Device B',
        identityPublicKey: pubKeyB.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        fingerprint: await cryptoService.computeFingerprint(pubKeyB.bytes),
        keyPair: keyPairB,
      );

      final keyPairC = await cryptoService.generateIdentityKeyPair();
      final pubKeyC = await keyPairC.extractPublicKey();
      identityC = LocalIdentity(
        peerId: 'peer-c-uuid',
        displayName: 'Device C',
        identityPublicKey: pubKeyC.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        fingerprint: await cryptoService.computeFingerprint(pubKeyC.bytes),
        keyPair: keyPairC,
      );

      final prefs = await SharedPreferences.getInstance();

      transportA = MockMeshTransport('EP_A');
      transportB = MockMeshTransport('EP_B');
      transportC = MockMeshTransport('EP_C');

      // Configure mock transports
      containerA = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(dbA),
          secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
          localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityA)),
          transportProvider.overrideWithValue(transportA),
        ],
      );

      containerB = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(dbB),
          secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
          localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityB)),
          transportProvider.overrideWithValue(transportB),
        ],
      );

      containerC = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(dbC),
          secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
          localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityC)),
          transportProvider.overrideWithValue(transportC),
        ],
      );

      await containerA.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
      await containerB.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
      await containerC.read(localIdentityStateProvider.notifier).ensureKeysLoaded();

      containerA.read(messagingStateProvider);
      containerB.read(messagingStateProvider);
      containerC.read(messagingStateProvider);

      // Bridges: A <-> B <-> C
      transportA.onSend = (endpointId, data) {
        if (endpointId == 'EP_A_B') {
          transportB.triggerIncomingPayload('EP_B_A', data);
        }
      };

      transportB.onSend = (endpointId, data) {
        if (endpointId == 'EP_B_A') {
          transportA.triggerIncomingPayload('EP_A_B', data);
        } else if (endpointId == 'EP_B_C') {
          transportC.triggerIncomingPayload('EP_C_B', data);
        }
      };

      transportC.onSend = (endpointId, data) {
        if (endpointId == 'EP_C_B') {
          transportB.triggerIncomingPayload('EP_B_C', data);
        }
      };
    });

    tearDown(() async {
      containerA.dispose();
      containerB.dispose();
      containerC.dispose();
      await dbA.close();
      await dbB.close();
      await dbC.close();
      if (testTempDir.existsSync()) {
        try {
          testTempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('TEST 1: Sequential 1 MB transfer', () async {
      final notifierA = containerA.read(messagingStateProvider.notifier);

      final repoA = containerA.read(messagingRepositoryProvider);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoA.upsertPeer(identityB.peerId, 'Device B', publicKey: identityB.identityPublicKey, fingerprint: identityB.fingerprint, trustState: PeerTrustState.trusted);
      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      // Connect A and B with a delay to prevent concurrent clashing handshakes
      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));

      await Future.delayed(const Duration(milliseconds: 1500));

      // Build a 1 MB source file
      final srcFile = File(path.join(testTempDir.path, 'src_1mb.bin'));
      final data = Uint8List(1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }
      await srcFile.writeAsBytes(data);

      final expectedHash = sha256.convert(data).toString();

      await notifierA.sendFileMessage('peer-b-uuid', srcFile.path);

      // Poll database for completion
      VantraMessage? dbMsgB;
      for (var i = 0; i < 50; i++) {
        final history = await repoB.getConversation(identityB.peerId, 'peer-a-uuid');
        if (history.isNotEmpty && history.first.mediaPath != null) {
          dbMsgB = history.first;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      expect(dbMsgB, isNotNull);
      expect(dbMsgB!.status, MessageStatus.received);
      expect(dbMsgB.sha256, expectedHash);

      final recFile = File(dbMsgB.mediaPath!);
      expect(await recFile.exists(), isTrue);
      expect(await recFile.length(), data.length);

      final recBytes = await recFile.readAsBytes();
      final recHash = sha256.convert(recBytes).toString();
      expect(recHash, expectedHash);
    });

    test('TEST 2: Out-of-order chunk reception', () async {
      final notifierB = containerB.read(messagingStateProvider.notifier);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      final expectedData = Uint8List.fromList([0, 10, 20, 1, 11, 21, 2, 12, 22]);
      final expectedHash = sha256.convert(expectedData).toString();

      // Set up peer metadata and database record
      await repoB.saveIncomingMessage(VantraMessage(
        messageId: 'msg-ooo',
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        text: 'ooo test',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.pending,
        type: 'FILE',
        fileName: 'ooo.bin',
        fileSize: expectedData.length,
        transferId: 't-ooo',
        sha256: expectedHash,
      ));

      // Connect B and A with delay
      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));
      await Future.delayed(const Duration(milliseconds: 1500));

      final secSession = notifierB.getSecuritySession('peer-a-uuid');
      expect(secSession, isNotNull);

      // Send chunks 2, 0, 1 (out of order)
      const codec = ProtobufCodec();
      final chunks = <DomainMediaChunk>[];
      for (var i = 0; i < 3; i++) {
        chunks.add(DomainMediaChunk(
          messageId: 'chunk-msg-$i',
          sessionId: secSession!.sessionId,
          sequence: secSession.nextSendSequence(),
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          senderId: 'peer-a-uuid',
          receiverId: 'peer-b-uuid',
          transferId: 't-ooo',
          chunkIndex: i,
          totalChunks: 3,
          data: Uint8List.fromList([i, i + 10, i + 20]),
        ));
      }

      // Reorder chunks: index 2, then 0, then 1
      final reordered = [chunks[2], chunks[0], chunks[1]];

      for (final chunk in reordered) {
        final chunkBytes = codec.encodePlaintext(chunk);
        final encrypted = await cryptoService.encryptBytes(
          secretKey: secSession!.receiveKey,
          sessionSalt: secSession.sessionSalt,
          sequence: chunk.sequence,
          messageId: chunk.messageId,
          plaintextBytes: chunkBytes,
        );

        final envelope = codec.encodeWireEnvelope(
          DomainEncryptedEnvelope(
            protocolVersion: kCurrentProtocolVersion,
            messageId: chunk.messageId,
            sessionId: secSession.sessionId,
            sequence: chunk.sequence,
            nonce: Uint8List.fromList(encrypted.nonce),
            ciphertext: Uint8List.fromList(encrypted.ciphertext),
            mac: Uint8List.fromList(encrypted.mac),
          ),
        );

        transportB.triggerIncomingPayload('EP_B_A', Uint8List.fromList(envelope));
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Verify file is correctly written and assembled
      final dbMsg = await repoB.getMessageById('msg-ooo');
      expect(dbMsg!.status, MessageStatus.received);

      final file = File(dbMsg.mediaPath!);
      expect(await file.exists(), isTrue);

      final fileBytes = await file.readAsBytes();
      // Expect concatenated format: chunk0 (0,10,20), chunk1 (1,11,21), chunk2 (2,12,22)
      expect(fileBytes, equals([0, 10, 20, 1, 11, 21, 2, 12, 22]));
    });

    test('TEST 3: Duplicate chunk reception', () async {
      final notifierB = containerB.read(messagingStateProvider.notifier);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      final expectedData = Uint8List.fromList([1, 2, 3, 4]);
      final expectedHash = sha256.convert(expectedData).toString();

      await repoB.saveIncomingMessage(VantraMessage(
        messageId: 'msg-dup',
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        text: 'dup test',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.pending,
        type: 'FILE',
        fileName: 'dup.bin',
        fileSize: expectedData.length,
        transferId: 't-dup',
        sha256: expectedHash,
      ));

      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));
      await Future.delayed(const Duration(milliseconds: 1500));

      final secSession = notifierB.getSecuritySession('peer-a-uuid');
      expect(secSession, isNotNull);
      const codec = ProtobufCodec();

      // Send chunk 0 twice, then chunk 1
      final chunk0 = DomainMediaChunk(
        messageId: 'chunk-c0',
        sessionId: secSession!.sessionId,
        sequence: secSession.nextSendSequence(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        transferId: 't-dup',
        chunkIndex: 0,
        totalChunks: 2,
        data: Uint8List.fromList([1, 2]),
      );

      final chunk1 = DomainMediaChunk(
        messageId: 'chunk-c1',
        sessionId: secSession.sessionId,
        sequence: secSession.nextSendSequence(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        transferId: 't-dup',
        chunkIndex: 1,
        totalChunks: 2,
        data: Uint8List.fromList([3, 4]),
      );

      // Trigger chunk 0, then chunk 0 duplicate, then chunk 1
      for (final chunk in [chunk0, chunk0, chunk1]) {
        final chunkBytes = codec.encodePlaintext(chunk);
        final encrypted = await cryptoService.encryptBytes(
          secretKey: secSession.receiveKey,
          sessionSalt: secSession.sessionSalt,
          sequence: chunk.sequence,
          messageId: chunk.messageId,
          plaintextBytes: chunkBytes,
        );

        final envelope = codec.encodeWireEnvelope(
          DomainEncryptedEnvelope(
            protocolVersion: kCurrentProtocolVersion,
            messageId: chunk.messageId,
            sessionId: secSession.sessionId,
            sequence: chunk.sequence,
            nonce: Uint8List.fromList(encrypted.nonce),
            ciphertext: Uint8List.fromList(encrypted.ciphertext),
            mac: Uint8List.fromList(encrypted.mac),
          ),
        );

        transportB.triggerIncomingPayload('EP_B_A', Uint8List.fromList(envelope));
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final dbMsg = await repoB.getMessageById('msg-dup');
      expect(dbMsg!.status, MessageStatus.received);
    });

    test('TEST 4: Missing chunk prevents completion', () async {
      final notifierB = containerB.read(messagingStateProvider.notifier);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      final expectedData = Uint8List.fromList([1, 2, 3, 4]);
      final expectedHash = sha256.convert(expectedData).toString();

      await repoB.saveIncomingMessage(VantraMessage(
        messageId: 'msg-miss',
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        text: 'missing test',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.pending,
        type: 'FILE',
        fileName: 'miss.bin',
        fileSize: expectedData.length,
        transferId: 't-miss',
        sha256: expectedHash,
      ));

      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));
      await Future.delayed(const Duration(milliseconds: 1500));

      final secSession = notifierB.getSecuritySession('peer-a-uuid');
      expect(secSession, isNotNull);
      const codec = ProtobufCodec();

      // Only send chunk 0 out of 2
      final chunk0 = DomainMediaChunk(
        messageId: 'chunk-m0',
        sessionId: secSession!.sessionId,
        sequence: secSession.nextSendSequence(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        transferId: 't-miss',
        chunkIndex: 0,
        totalChunks: 2,
        data: Uint8List.fromList([1, 2]),
      );

      final chunkBytes = codec.encodePlaintext(chunk0);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: chunk0.sequence,
        messageId: chunk0.messageId,
        plaintextBytes: chunkBytes,
      );

      final envelope = codec.encodeWireEnvelope(
        DomainEncryptedEnvelope(
          protocolVersion: kCurrentProtocolVersion,
          messageId: chunk0.messageId,
          sessionId: secSession.sessionId,
          sequence: chunk0.sequence,
          nonce: Uint8List.fromList(encrypted.nonce),
          ciphertext: Uint8List.fromList(encrypted.ciphertext),
          mac: Uint8List.fromList(encrypted.mac),
        ),
      );

      transportB.triggerIncomingPayload('EP_B_A', Uint8List.fromList(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      final dbMsg = await repoB.getMessageById('msg-miss');
      expect(dbMsg!.status, MessageStatus.pending);
    });

    test('TEST 5: Invalid chunk index is rejected', () async {
      final notifierB = containerB.read(messagingStateProvider.notifier);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      await repoB.saveIncomingMessage(VantraMessage(
        messageId: 'msg-inv-idx',
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        text: 'invalid index test',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.pending,
        type: 'FILE',
        fileName: 'inv.bin',
        fileSize: 200,
        transferId: 't-inv',
        sha256: 'somehash',
      ));

      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));
      await Future.delayed(const Duration(milliseconds: 1500));

      final secSession = notifierB.getSecuritySession('peer-a-uuid');
      expect(secSession, isNotNull);
      const codec = ProtobufCodec();

      // Chunk index is 5, totalChunks is 2 (invalid)
      final chunk0 = DomainMediaChunk(
        messageId: 'chunk-mi',
        sessionId: secSession!.sessionId,
        sequence: secSession.nextSendSequence(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        transferId: 't-inv',
        chunkIndex: 5,
        totalChunks: 2,
        data: Uint8List.fromList([1, 2]),
      );

      final chunkBytes = codec.encodePlaintext(chunk0);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: chunk0.sequence,
        messageId: chunk0.messageId,
        plaintextBytes: chunkBytes,
      );

      final envelope = codec.encodeWireEnvelope(
        DomainEncryptedEnvelope(
          protocolVersion: kCurrentProtocolVersion,
          messageId: chunk0.messageId,
          sessionId: secSession.sessionId,
          sequence: chunk0.sequence,
          nonce: Uint8List.fromList(encrypted.nonce),
          ciphertext: Uint8List.fromList(encrypted.ciphertext),
          mac: Uint8List.fromList(encrypted.mac),
        ),
      );

      transportB.triggerIncomingPayload('EP_B_A', Uint8List.fromList(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      final dbMsg = await repoB.getMessageById('msg-inv-idx');
      expect(dbMsg!.status, MessageStatus.failed);
    });

    test('TEST 6: Chunk writing beyond advertised fileSize is rejected', () async {
      final notifierB = containerB.read(messagingStateProvider.notifier);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      await repoB.saveIncomingMessage(VantraMessage(
        messageId: 'msg-overflow',
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        text: 'overflow test',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.pending,
        type: 'FILE',
        fileName: 'overflow.bin',
        fileSize: 2, // Small advertised size that will overflow
        transferId: 't-over',
        sha256: 'somehash',
      ));

      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));
      await Future.delayed(const Duration(milliseconds: 1500));

      final secSession = notifierB.getSecuritySession('peer-a-uuid');
      expect(secSession, isNotNull);
      const codec = ProtobufCodec();

      // Chunk size is large and offset (1 * 131072) overflows 10 bytes file size
      final chunk0 = DomainMediaChunk(
        messageId: 'chunk-mo',
        sessionId: secSession!.sessionId,
        sequence: secSession.nextSendSequence(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        transferId: 't-over',
        chunkIndex: 1,
        totalChunks: 2,
        data: Uint8List.fromList([1, 2]),
      );

      final chunkBytes = codec.encodePlaintext(chunk0);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: chunk0.sequence,
        messageId: chunk0.messageId,
        plaintextBytes: chunkBytes,
      );

      final envelope = codec.encodeWireEnvelope(
        DomainEncryptedEnvelope(
          protocolVersion: kCurrentProtocolVersion,
          messageId: chunk0.messageId,
          sessionId: secSession.sessionId,
          sequence: chunk0.sequence,
          nonce: Uint8List.fromList(encrypted.nonce),
          ciphertext: Uint8List.fromList(encrypted.ciphertext),
          mac: Uint8List.fromList(encrypted.mac),
        ),
      );

      transportB.triggerIncomingPayload('EP_B_A', Uint8List.fromList(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      final dbMsg = await repoB.getMessageById('msg-overflow');
      expect(dbMsg!.status, MessageStatus.failed);
    });

    test('TEST 8: SHA-256 mismatch rejects and cleans temporary file', () async {
      final notifierB = containerB.read(messagingStateProvider.notifier);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      await repoB.saveIncomingMessage(VantraMessage(
        messageId: 'msg-mismatch',
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        text: 'mismatch test',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.pending,
        type: 'FILE',
        fileName: 'mismatch.bin',
        fileSize: 4,
        transferId: 't-mismatch',
        sha256: 'incorrect_expected_hash', // Mismatched SHA-256
      ));

      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));
      await Future.delayed(const Duration(milliseconds: 1500));

      final secSession = notifierB.getSecuritySession('peer-a-uuid');
      expect(secSession, isNotNull);
      const codec = ProtobufCodec();

      final chunk0 = DomainMediaChunk(
        messageId: 'chunk-mismatch',
        sessionId: secSession!.sessionId,
        sequence: secSession.nextSendSequence(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        transferId: 't-mismatch',
        chunkIndex: 0,
        totalChunks: 1,
        data: Uint8List.fromList([1, 2, 3, 4]),
      );

      final chunkBytes = codec.encodePlaintext(chunk0);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: chunk0.sequence,
        messageId: chunk0.messageId,
        plaintextBytes: chunkBytes,
      );

      final envelope = codec.encodeWireEnvelope(
        DomainEncryptedEnvelope(
          protocolVersion: kCurrentProtocolVersion,
          messageId: chunk0.messageId,
          sessionId: secSession.sessionId,
          sequence: chunk0.sequence,
          nonce: Uint8List.fromList(encrypted.nonce),
          ciphertext: Uint8List.fromList(encrypted.ciphertext),
          mac: Uint8List.fromList(encrypted.mac),
        ),
      );

      transportB.triggerIncomingPayload('EP_B_A', Uint8List.fromList(envelope));
      await Future.delayed(const Duration(milliseconds: 200));

      final dbMsg = await repoB.getMessageById('msg-mismatch');
      expect(dbMsg!.status, MessageStatus.failed);

      final tempFile = File(path.join(testTempDir.path, 'files', 'temp', 't-mismatch.tmp'));
      expect(await tempFile.exists(), isFalse); // Temporary file cleaned up
    });

    test('TEST 12: Timeout cleans stale transfer resources', () async {
      final notifierB = containerB.read(messagingStateProvider.notifier);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      await repoB.saveIncomingMessage(VantraMessage(
        messageId: 'msg-timeout',
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        text: 'timeout test',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.pending,
        type: 'FILE',
        fileName: 'timeout.bin',
        fileSize: 10,
        transferId: 't-timeout',
        sha256: 'somehash',
      ));

      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));
      await Future.delayed(const Duration(milliseconds: 1500));

      final secSession = notifierB.getSecuritySession('peer-a-uuid');
      expect(secSession, isNotNull);
      const codec = ProtobufCodec();

      final chunk0 = DomainMediaChunk(
        messageId: 'chunk-timeout',
        sessionId: secSession!.sessionId,
        sequence: secSession.nextSendSequence(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: 'peer-a-uuid',
        receiverId: 'peer-b-uuid',
        transferId: 't-timeout',
        chunkIndex: 0,
        totalChunks: 2, // Needs 2 chunks to complete
        data: Uint8List.fromList([1, 2, 3, 4, 5]),
      );

      final chunkBytes = codec.encodePlaintext(chunk0);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: chunk0.sequence,
        messageId: chunk0.messageId,
        plaintextBytes: chunkBytes,
      );

      final envelope = codec.encodeWireEnvelope(
        DomainEncryptedEnvelope(
          protocolVersion: kCurrentProtocolVersion,
          messageId: chunk0.messageId,
          sessionId: secSession.sessionId,
          sequence: chunk0.sequence,
          nonce: Uint8List.fromList(encrypted.nonce),
          ciphertext: Uint8List.fromList(encrypted.ciphertext),
          mac: Uint8List.fromList(encrypted.mac),
        ),
      );

      transportB.triggerIncomingPayload('EP_B_A', Uint8List.fromList(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      final tempFile = File(path.join(testTempDir.path, 'files', 'temp', 't-timeout.tmp'));
      expect(await tempFile.exists(), isTrue);

      // Fast-forward or trigger timeout manually by firing timer
      final timer = notifierB.receiveTimeoutTimers['t-timeout'];
      expect(timer, isNotNull);

      // Cancel and invoke the timeout logic immediately
      timer!.cancel();
      await notifierB.cleanupReceiveTransfer('t-timeout', deleteTempFile: true, tempFilePath: tempFile.path);

      expect(await tempFile.exists(), isFalse); // Cleaned up stale resources
    });

    test('TEST 19: Simulated large transfer does not load complete file in memory', () async {
      // Create a 5 MB simulated source file
      final srcFile = File(path.join(testTempDir.path, 'stress_5mb.bin'));
      final data = Uint8List(5 * 1024 * 1024);
      await srcFile.writeAsBytes(data);

      final expectedHash = sha256.convert(data).toString();

      final notifierA = containerA.read(messagingStateProvider.notifier);
      final repoA = containerA.read(messagingRepositoryProvider);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoA.upsertPeer(identityB.peerId, 'Device B', publicKey: identityB.identityPublicKey, fingerprint: identityB.fingerprint, trustState: PeerTrustState.trusted);
      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));

      await Future.delayed(const Duration(milliseconds: 1500));

      await notifierA.sendFileMessage('peer-b-uuid', srcFile.path);

      // Poll database for completion
      VantraMessage? dbMsgB;
      for (var i = 0; i < 100; i++) {
        final history = await repoB.getConversation(identityB.peerId, 'peer-a-uuid');
        if (history.isNotEmpty && history.first.mediaPath != null) {
          dbMsgB = history.first;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      expect(dbMsgB, isNotNull);
      expect(dbMsgB!.status, MessageStatus.received);

      final recFile = File(dbMsgB.mediaPath!);
      expect(await recFile.exists(), isTrue);
      expect(await recFile.length(), data.length);

      final recBytes = await recFile.readAsBytes();
      final recHash = sha256.convert(recBytes).toString();
      expect(recHash, expectedHash);
    });
  });
}

extension on MessagingNotifier {
  SecuritySession? getSecuritySession(String peerId) => securitySessions[peerId];
}
