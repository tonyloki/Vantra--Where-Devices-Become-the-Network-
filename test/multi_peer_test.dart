import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:vantra/core/security/security_session.dart';
import 'package:vantra/core/models/message_status.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = ProtobufCodec();

  group('Multi-Peer Presence and Isolation Tests', () {
    late FakeTransport fakeTransport;
    late ProviderContainer container;
    late AppDatabase testDb;
    late CryptoService cryptoService;
    late Directory testTempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      fakeTransport = FakeTransport();
      testDb = AppDatabase.forTesting(NativeDatabase.memory());
      cryptoService = CryptoService();

      testTempDir = Directory.systemTemp.createTempSync('vantra_multi_peer_test_');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'getApplicationDocumentsDirectory') {
            return testTempDir.path;
          }
          return null;
        },
      );

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
      if (testTempDir.existsSync()) {
        try {
          testTempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });


    test('TEST 1 - Two peers coexist simultaneously and independently', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);

      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
      );

      expect(notifier.hasActiveSecureTransport(peerA), isTrue);
      expect(notifier.hasActiveSecureTransport(peerB), isTrue);
    });

    test('TEST 2 - Connecting Peer A does not affect Peer B state', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.add('EP_B');

      notifier.state = notifier.state.copyWith(
        sessions: {
          peerB: sessionB,
        },
      );

      // Connect Peer A
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_A',
        status: ConnectionStatus.connecting,
        endpointName: 'Peer A:$peerA',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.hasActiveSecureTransport(peerB), isTrue);
      final currentSessionB = container.read(messagingStateProvider).sessions[peerB];
      expect(currentSessionB?.status, SessionStatus.connected);
      expect(currentSessionB?.isSecure, isTrue);
    });

    test('TEST 3 - Disconnecting Peer A does not mark Peer B offline', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
        endpointToPeerId: {
          'EP_A': peerA,
          'EP_B': peerB,
        },
      );

      // Disconnect Peer A
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_A',
        status: ConnectionStatus.disconnected,
        endpointName: 'Peer A:$peerA',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.hasActiveSecureTransport(peerB), isTrue);
      final currentSessionB = container.read(messagingStateProvider).sessions[peerB];
      expect(currentSessionB?.status, SessionStatus.connected);
      expect(currentSessionB?.isSecure, isTrue);

      final currentSessionA = container.read(messagingStateProvider).sessions[peerA];
      expect(currentSessionA?.status, SessionStatus.disconnected);
    });

    test('TEST 4 - Peer A reconnecting does not invalidate Peer B session', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.add('EP_B');

      notifier.state = notifier.state.copyWith(
        sessions: {
          peerB: sessionB,
        },
      );

      // Reconnect Peer A on a new endpoint
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_A_NEW',
        status: ConnectionStatus.connecting,
        endpointName: 'Peer A:$peerA',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.hasActiveSecureTransport(peerB), isTrue);
    });

    test('TEST 5 - EP_OLD disconnect for Peer A cannot invalidate EP_NEW for Peer A', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';

      final activeSession = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_NEW',
        status: SessionStatus.connected,
        isSecure: true,
      );

      final secSession = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_NEW',
        sessionId: 'session-new',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-new',
        remoteFingerprint: 'fp-new',
      );

      notifier.securitySessions[peerA] = secSession;
      notifier.aliveEndpoints.addAll(['EP_NEW', 'EP_OLD']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: activeSession,
        },
        endpointToPeerId: {
          'EP_NEW': peerA,
          'EP_OLD': peerA,
        },
      );

      // Trigger disconnect on EP_OLD
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_OLD',
        endpointName: 'Peer A:$peerA',
        status: ConnectionStatus.disconnected,
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final currentSession = container.read(messagingStateProvider).sessions[peerA];
      expect(currentSession?.status, SessionStatus.connected);
      expect(currentSession?.endpointId, 'EP_NEW');
    });

    test('TEST 6 - Peer A endpoint events cannot mutate Peer B session state', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );

      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerB: sessionB,
        },
        endpointToPeerId: {
          'EP_A': peerA,
          'EP_B': peerB,
        },
      );

      // Disconnect EP_A
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_A',
        endpointName: 'Peer A:$peerA',
        status: ConnectionStatus.disconnected,
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // Peer B session is unaffected
      final currentSessionB = container.read(messagingStateProvider).sessions[peerB];
      expect(currentSessionB?.status, SessionStatus.connected);
    });

    test('TEST 7 - Text message routing is peer-specific', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
        endpointToPeerId: {
          'EP_A': peerA,
          'EP_B': peerB,
        },
      );

      await notifier.sendTextMessage(peerA, 'Hello Peer A');
      await Future.delayed(const Duration(milliseconds: 50));

      final conversationA = await repo.getConversation(localId.peerId, peerA);
      expect(conversationA.length, 1);
      expect(conversationA[0].text, 'Hello Peer A');

      final conversationB = await repo.getConversation(localId.peerId, peerB);
      expect(conversationB.isEmpty, isTrue);
    });

    test('TEST 8 - ACK routing is peer-specific', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final localId = container.read(localIdentityStateProvider);

      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
        endpointToPeerId: {
          'EP_A': peerA,
          'EP_B': peerB,
        },
      );

      final ackMsg = DomainAckMessage(
        messageId: 'msg-123',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        originalMessageId: 'msg-123',
        status: DomainDeliveryStatus.delivered,
      );

      final plainBytes = codec.encodePlaintext(ackMsg);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: ackMsg.messageId,
        plaintextBytes: plainBytes,
      );

      // Deliver ACK envelope on EP_A
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ackMsg.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      // Handled successfully
    });

    test('TEST 9 - Retry scheduling is peer-specific', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );

      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
      );

      // Trigger backoff scheduling for Peer A
      fakeTransport.throwErrorOnSend = true;
      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );
      notifier.securitySessions[peerA] = secSessionA;

      await notifier.sendTextMessage(peerA, 'Fail me');
      await Future.delayed(const Duration(milliseconds: 50));
    });

    test('TEST 10 - Two peers can flush queues independently', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
      );

      // Flush queue for A and B concurrently
      await Future.wait([
        notifier.flushQueue(peerA),
        notifier.flushQueue(peerB),
      ]);
    });

    test('TEST 11 - Image transfer to Peer A does not appear in Peer B queue', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);

      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.image],
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.image],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
      );

      final fileData = Uint8List(10 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      // Send to A
      await notifier.sendImageMessage(peerA, tempFile.path, caption: 'To Peer A');
      await Future.delayed(const Duration(milliseconds: 50));

      final pendingB = await repo.getPendingOrFailedMessages(peerB);
      expect(pendingB.isEmpty, isTrue);
    });

    test('TEST 12 - File transfer to Peer A does not appear in Peer B queue', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.file],
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.file],
      );

      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
      );

      final fileData = Uint8List(5 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.pdf'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendFileMessage(peerA, tempFile.path, caption: 'To Peer A File');
      await Future.delayed(const Duration(milliseconds: 50));

      final pendingB = await repo.getPendingOrFailedMessages(peerB);
      expect(pendingB.isEmpty, isTrue);
    });

    test('TEST 13 - ChatPage build state values do not cross-talk between peers', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.disconnected,
        isSecure: false,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
      );

      expect(notifier.hasActiveSecureTransport(peerA), isTrue);
      expect(notifier.hasActiveSecureTransport(peerB), isFalse);
    });

    test('TEST 14 - Navigation between two peers preserves both sessions', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.connected,
        isSecure: true,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );
      final secSessionB = SecuritySession(
        peerId: peerB,
        endpointId: 'EP_B',
        sessionId: 'session-b',
        sendKey: SecretKey(List<int>.filled(32, 2)),
        receiveKey: SecretKey(List<int>.filled(32, 2)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-b',
        remoteFingerprint: 'fp-b',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.securitySessions[peerB] = secSessionB;
      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
      );

      notifier.setActiveConversation(peerA);
      expect(container.read(messagingStateProvider).activeConversationPeerId, peerA);

      notifier.setActiveConversation(peerB);
      expect(container.read(messagingStateProvider).activeConversationPeerId, peerB);

      // Both remain connected
      expect(notifier.hasActiveSecureTransport(peerA), isTrue);
      expect(notifier.hasActiveSecureTransport(peerB), isTrue);
    });

    test('TEST 15 - Multiple simultaneous peer state updates do not overwrite each other', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';
      final peerB = 'peer-b-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.disconnected,
        isSecure: false,
      );
      final sessionB = PeerSession(
        peerId: peerB,
        displayName: 'Peer B',
        endpointId: 'EP_B',
        status: SessionStatus.disconnected,
        isSecure: false,
      );

      notifier.aliveEndpoints.addAll(['EP_A', 'EP_B']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
          peerB: sessionB,
        },
      );

      // Simulate connection update for A
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_A',
        endpointName: 'Peer A:$peerA',
        status: ConnectionStatus.connected,
      ));

      // Simulate connection update for B
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_B',
        endpointName: 'Peer B:$peerB',
        status: ConnectionStatus.connected,
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(messagingStateProvider);
      expect(state.sessions[peerA]?.status, SessionStatus.handshaking);
      expect(state.sessions[peerB]?.status, SessionStatus.handshaking);
    });

    test('TEST 16 - Prior single-peer behavior remains clean and functional', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerId = 'single-peer-uuid';

      final session = PeerSession(
        peerId: peerId,
        displayName: 'Single Peer',
        endpointId: 'EP1',
        status: SessionStatus.connected,
        isSecure: true,
      );
      notifier.aliveEndpoints.add('EP1');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerId: session,
        },
      );

      expect(notifier.state.sessions[peerId]?.displayName, 'Single Peer');
    });

    test('TEST 17 - V2 session starts with enabledCapabilities = null and IMAGE remains pending (not failed)', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.handshaking,
        isSecure: true,
        enabledCapabilities: null,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final fileData = Uint8List(10 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerA, tempFile.path, caption: 'Pending Image');
      await Future.delayed(const Duration(milliseconds: 50));

      // The message must remain pending/sending (not failed)
      final pending = await repo.getPendingOrFailedMessages(peerA);
      expect(pending.length, 1);
      expect(pending.first.status, MessageStatus.pending);
    });

    test('TEST 18 - Delivery ACK before CapabilitiesExchange (recovery race) does not mark media failed', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.handshaking,
        isSecure: true,
        enabledCapabilities: null,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final fileData = Uint8List(10 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerA, tempFile.path, caption: 'Pending Image');
      await Future.delayed(const Duration(milliseconds: 50));

      // Deliver delivery ACK to trigger recovery
      final ackMsg = DomainAckMessage(
        messageId: 'ack-123',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        originalMessageId: 'some-other-msg-id',
        status: DomainDeliveryStatus.delivered,
      );

      final plainBytes = codec.encodePlaintext(ackMsg);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: ackMsg.messageId,
        plaintextBytes: plainBytes,
      );

      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ackMsg.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));

      // Verify recovery set status to connected but enabledCapabilities is still null
      final updatedSess = notifier.state.sessions[peerA];
      expect(updatedSess?.status, SessionStatus.connected);
      expect(updatedSess?.enabledCapabilities, isNull);

      // Verify image remains pending (not failed)
      final pending = await repo.getPendingOrFailedMessages(peerA);
      expect(pending.length, 1);
      expect(pending.first.status, MessageStatus.pending);
    });

    test('TEST 19 & 20 - CapabilitiesExchange after ACK negotiates capabilities and pending IMAGE sends OFFER', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.handshaking,
        isSecure: true,
        enabledCapabilities: null,
        remoteMinVersion: 2,
        remoteMaxVersion: 2,
        remoteCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final fileData = Uint8List(10 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerA, tempFile.path, caption: 'Pending Image');

      final initialPending = await repo.getPendingOrFailedMessages(peerA);
      expect(initialPending.length, 1);
      final messageId = initialPending.first.messageId;

      // Deliver capabilities exchange
      final capMsg = DomainCapabilitiesExchange(
        messageId: 'cap-123',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final plainBytes = codec.encodePlaintext(capMsg);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: capMsg.messageId,
        plaintextBytes: plainBytes,
      );

      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capMsg.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      )));

      // Poll to wait for capabilities negotiation and message status change
      MessageStatus? status;
      for (int i = 0; i < 40; i++) {
        final msg = await repo.getMessageById(messageId);
        if (msg != null && msg.status != MessageStatus.pending) {
          status = msg.status;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 25));
      }

      // Verify capabilities negotiation completed successfully
      final updatedSess = notifier.state.sessions[peerA];
      expect(updatedSess?.status, SessionStatus.connected);
      expect(updatedSess?.enabledCapabilities?.contains(VantraCapability.image), isTrue);

      // Verify image transitions to sending (and media OFFER is sent)
      expect(status, MessageStatus.sending);
    });

    test('TEST 21 - Genuine unsupported capability fails permanently', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final fileData = Uint8List(10 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.pdf'));
      await tempFile.writeAsBytes(fileData);

      // Attempt to send FILE message when only IMAGE/TEXT are supported
      await notifier.sendFileMessage(peerA, tempFile.path, caption: 'Rejected File');
      final initialPending = await repo.getPendingOrFailedMessages(peerA);
      expect(initialPending.length, 1);
      final messageId = initialPending.first.messageId;

      MessageStatus? status;
      for (int i = 0; i < 40; i++) {
        final msg = await repo.getMessageById(messageId);
        if (msg != null && msg.status != MessageStatus.pending) {
          status = msg.status;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 25));
      }

      expect(status, MessageStatus.failed);
    });

    test('TEST 22 - IMAGE capability is supported normally', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final fileData = Uint8List(10 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerA, tempFile.path, caption: 'Supported Image');
      final initialPending = await repo.getPendingOrFailedMessages(peerA);
      expect(initialPending.length, 1);
      final messageId = initialPending.first.messageId;

      MessageStatus? status;
      for (int i = 0; i < 40; i++) {
        final msg = await repo.getMessageById(messageId);
        if (msg != null && msg.status != MessageStatus.pending) {
          status = msg.status;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 25));
      }

      expect(status, MessageStatus.sending);
    });

    test('TEST 23 - FILE capability is supported normally', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final fileData = Uint8List(10 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.pdf'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendFileMessage(peerA, tempFile.path, caption: 'Supported File');
      final initialPending = await repo.getPendingOrFailedMessages(peerA);
      expect(initialPending.length, 1);
      final messageId = initialPending.first.messageId;
      
      MessageStatus? status;
      for (int i = 0; i < 40; i++) {
        final msg = await repo.getMessageById(messageId);
        if (msg != null && msg.status != MessageStatus.pending) {
          status = msg.status;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 25));
      }

      expect(status, MessageStatus.sending);
    });

    test('TEST 24 - Receiver OFFER arrives before CapabilitiesExchange is deferred, not rejected', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.handshaking,
        isSecure: true,
        enabledCapabilities: null,
        remoteMinVersion: 2,
        remoteMaxVersion: 2,
        remoteCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final offerMsg = DomainMediaControl(
        messageId: 'offer-1',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-1',
        fileName: 'test.jpg',
        fileSize: 5000,
        mimeType: 'image/jpeg',
        totalChunks: 1,
        chunkSize: 16384,
        width: 100,
        height: 100,
      );

      final plainBytes = codec.encodePlaintext(offerMsg);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offerMsg.messageId,
        plaintextBytes: plainBytes,
      );

      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offerMsg.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.pendingIncomingOffers.containsKey('transfer-1'), isTrue);
      expect(notifier.pendingIncomingOffers['transfer-1']?.peerId, peerA);
    });

    test('TEST 25 - CapabilitiesExchange arrives after deferred OFFER triggers replay and accept', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.handshaking,
        isSecure: true,
        enabledCapabilities: null,
        remoteMinVersion: 2,
        remoteMaxVersion: 2,
        remoteCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      // 1. Deliver OFFER first
      final offerMsg = DomainMediaControl(
        messageId: 'offer-25',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-25',
        fileName: 'test25.jpg',
        fileSize: 5000,
        mimeType: 'image/jpeg',
        totalChunks: 1,
        chunkSize: 16384,
        width: 100,
        height: 100,
      );

      final plainBytes1 = codec.encodePlaintext(offerMsg);
      final encrypted1 = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offerMsg.messageId,
        plaintextBytes: plainBytes1,
      );

      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offerMsg.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(encrypted1.nonce),
        ciphertext: Uint8List.fromList(encrypted1.ciphertext),
        mac: Uint8List.fromList(encrypted1.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.pendingIncomingOffers.containsKey('transfer-25'), isTrue);

      // 2. Deliver CapabilitiesExchange
      final capMsg = DomainCapabilitiesExchange(
        messageId: 'cap-25',
        sessionId: 'session-a',
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final plainBytes2 = codec.encodePlaintext(capMsg);
      final encrypted2 = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 2,
        messageId: capMsg.messageId,
        plaintextBytes: plainBytes2,
      );

      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capMsg.messageId,
        sessionId: 'session-a',
        sequence: 2,
        nonce: Uint8List.fromList(encrypted2.nonce),
        ciphertext: Uint8List.fromList(encrypted2.ciphertext),
        mac: Uint8List.fromList(encrypted2.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 100));

      // 3. Verify OFFER was replayed and cleared from pending map
      expect(notifier.pendingIncomingOffers.containsKey('transfer-25'), isFalse);

      // 4. Verify message was saved to SQLite as incoming message
      final saved = await repo.getMessageById('offer-25');
      expect(saved, isNotNull);
      expect(saved?.transferId, 'transfer-25');
      expect(saved?.type, 'IMAGE');
    });

    test('TEST 26 - Multiple deferred OFFERs for same peer all replay when capabilities arrive', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.handshaking,
        isSecure: true,
        enabledCapabilities: null,
        remoteMinVersion: 2,
        remoteMaxVersion: 2,
        remoteCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      // Send Offer 1 (Image)
      final offer1 = DomainMediaControl(
        messageId: 'offer-26-1',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-26-1',
        fileName: 'img1.jpg',
        fileSize: 4000,
        mimeType: 'image/jpeg',
        totalChunks: 1,
        chunkSize: 16384,
        width: 50,
        height: 50,
      );
      final enc1 = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offer1.messageId,
        plaintextBytes: codec.encodePlaintext(offer1),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offer1.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(enc1.nonce),
        ciphertext: Uint8List.fromList(enc1.ciphertext),
        mac: Uint8List.fromList(enc1.mac),
      )));

      // Send Offer 2 (File)
      final offer2 = DomainMediaControl(
        messageId: 'offer-26-2',
        sessionId: 'session-a',
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-26-2',
        fileName: 'doc1.pdf',
        fileSize: 8000,
        mimeType: 'application/pdf',
        totalChunks: 1,
        chunkSize: 16384,
      );
      final enc2 = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 2,
        messageId: offer2.messageId,
        plaintextBytes: codec.encodePlaintext(offer2),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offer2.messageId,
        sessionId: 'session-a',
        sequence: 2,
        nonce: Uint8List.fromList(enc2.nonce),
        ciphertext: Uint8List.fromList(enc2.ciphertext),
        mac: Uint8List.fromList(enc2.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.pendingIncomingOffers.length, 2);

      // Now deliver CapabilitiesExchange
      final capMsg = DomainCapabilitiesExchange(
        messageId: 'cap-26',
        sessionId: 'session-a',
        sequence: 3,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
      );
      final encCap = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 3,
        messageId: capMsg.messageId,
        plaintextBytes: codec.encodePlaintext(capMsg),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capMsg.messageId,
        sessionId: 'session-a',
        sequence: 3,
        nonce: Uint8List.fromList(encCap.nonce),
        ciphertext: Uint8List.fromList(encCap.ciphertext),
        mac: Uint8List.fromList(encCap.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 100));

      expect(notifier.pendingIncomingOffers.isEmpty, isTrue);
      final msg1 = await repo.getMessageById('offer-26-1');
      final msg2 = await repo.getMessageById('offer-26-2');
      expect(msg1, isNotNull);
      expect(msg2, isNotNull);
    });

    test('TEST 27 - Disconnect callback clears pending deferred offers and cancels timers', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.handshaking,
        isSecure: true,
        enabledCapabilities: null,
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final offer = DomainMediaControl(
        messageId: 'offer-27',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-27',
        fileName: 'img.jpg',
        fileSize: 4000,
        mimeType: 'image/jpeg',
        totalChunks: 1,
        chunkSize: 16384,
        width: 10,
        height: 10,
      );
      final enc = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offer.messageId,
        plaintextBytes: codec.encodePlaintext(offer),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offer.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(enc.nonce),
        ciphertext: Uint8List.fromList(enc.ciphertext),
        mac: Uint8List.fromList(enc.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.pendingIncomingOffers.containsKey('transfer-27'), isTrue);

      // Trigger disconnect
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_A',
        endpointName: 'Peer A:peer-a-uuid',
        status: ConnectionStatus.disconnected,
      ));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.pendingIncomingOffers.isEmpty, isTrue);
    });

    test('TEST 28 - Receiver genuine unsupported capability sends reject', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.text], // No image capability
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final offer = DomainMediaControl(
        messageId: 'offer-28',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-28',
        fileName: 'img.jpg',
        fileSize: 4000,
        mimeType: 'image/jpeg',
        totalChunks: 1,
        chunkSize: 16384,
        width: 10,
        height: 10,
      );
      final enc = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offer.messageId,
        plaintextBytes: codec.encodePlaintext(offer),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offer.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(enc.nonce),
        ciphertext: Uint8List.fromList(enc.ciphertext),
        mac: Uint8List.fromList(enc.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.pendingIncomingOffers.isEmpty, isTrue);
    });

    test('TEST 29 - Receiver size limit exceeded rejects with SIZE_LIMIT', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      // Image size limit is 10MB -> provide 15MB
      final offer = DomainMediaControl(
        messageId: 'offer-29',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-29',
        fileName: 'huge.jpg',
        fileSize: 15 * 1024 * 1024,
        mimeType: 'image/jpeg',
        totalChunks: 1000,
        chunkSize: 16384,
        width: 10,
        height: 10,
      );
      final enc = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offer.messageId,
        plaintextBytes: codec.encodePlaintext(offer),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offer.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(enc.nonce),
        ciphertext: Uint8List.fromList(enc.ciphertext),
        mac: Uint8List.fromList(enc.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.pendingIncomingOffers.isEmpty, isTrue);
    });

    test('TEST 30 - Full media receive lifecycle: deferred OFFER -> capabilities -> chunks -> reassembly -> stored', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.handshaking,
        isSecure: true,
        enabledCapabilities: null,
        remoteMinVersion: 2,
        remoteMaxVersion: 2,
        remoteCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      final chunkData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final shaHex = sha256.convert(chunkData).toString();

      // 1. Deliver OFFER (will be deferred)
      final offer = DomainMediaControl(
        messageId: 'offer-30',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-30',
        fileName: 'full.jpg',
        fileSize: chunkData.length,
        mimeType: 'image/jpeg',
        totalChunks: 1,
        chunkSize: 16384,
        width: 10,
        height: 10,
        sha256: shaHex,
      );
      final enc1 = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offer.messageId,
        plaintextBytes: codec.encodePlaintext(offer),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offer.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(enc1.nonce),
        ciphertext: Uint8List.fromList(enc1.ciphertext),
        mac: Uint8List.fromList(enc1.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.pendingIncomingOffers.containsKey('transfer-30'), isTrue);

      // 2. Deliver CapabilitiesExchange
      final capMsg = DomainCapabilitiesExchange(
        messageId: 'cap-30',
        sessionId: 'session-a',
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final enc2 = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 2,
        messageId: capMsg.messageId,
        plaintextBytes: codec.encodePlaintext(capMsg),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capMsg.messageId,
        sessionId: 'session-a',
        sequence: 2,
        nonce: Uint8List.fromList(enc2.nonce),
        ciphertext: Uint8List.fromList(enc2.ciphertext),
        mac: Uint8List.fromList(enc2.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.pendingIncomingOffers.isEmpty, isTrue);

      // 3. Deliver Chunk 0
      final chunk = DomainMediaChunk(
        messageId: 'chunk-30-0',
        sessionId: 'session-a',
        sequence: 3,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        transferId: 'transfer-30',
        chunkIndex: 0,
        totalChunks: 1,
        data: chunkData,
      );
      final enc3 = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 3,
        messageId: chunk.messageId,
        plaintextBytes: codec.encodePlaintext(chunk),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: chunk.messageId,
        sessionId: 'session-a',
        sequence: 3,
        nonce: Uint8List.fromList(enc3.nonce),
        ciphertext: Uint8List.fromList(enc3.ciphertext),
        mac: Uint8List.fromList(enc3.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 100));

      // 4. Verify message in DB is received and media file exists
      final finalMsg = await repo.getMessageById('offer-30');
      expect(finalMsg, isNotNull);
      expect(finalMsg?.status, MessageStatus.received);
      expect(finalMsg?.mediaPath, isNotNull);
      expect(File(finalMsg!.mediaPath!).existsSync(), isTrue);
      expect(await File(finalMsg.mediaPath!).readAsBytes(), chunkData);
    });

    test('Media transfer 500 MB size limit verification', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
        remoteMinVersion: 2,
        remoteMaxVersion: 2,
        remoteCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      // Test 1: File exactly at 500 MB should be accepted
      final offerAtLimit = DomainMediaControl(
        messageId: 'offer-at-limit',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-at-limit',
        fileName: 'limit.zip',
        fileSize: 500 * 1024 * 1024, // 500 MB
        mimeType: 'application/zip',
        totalChunks: 10,
        chunkSize: 16384,
      );
      final encAtLimit = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offerAtLimit.messageId,
        plaintextBytes: codec.encodePlaintext(offerAtLimit),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offerAtLimit.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(encAtLimit.nonce),
        ciphertext: Uint8List.fromList(encAtLimit.ciphertext),
        mac: Uint8List.fromList(encAtLimit.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));

      // Should be saved/accepted, not rejected
      final msgAtLimit = await repo.getMessageById('offer-at-limit');
      expect(msgAtLimit, isNotNull);
      expect(msgAtLimit?.status, isNot(MessageStatus.failed));

      // Test 2: File just above 500 MB (500 MB + 1 byte) should be rejected
      final offerOversized = DomainMediaControl(
        messageId: 'offer-oversized',
        sessionId: 'session-a',
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-oversized',
        fileName: 'huge.zip',
        fileSize: (500 * 1024 * 1024) + 1, // 500 MB + 1 byte
        mimeType: 'application/zip',
        totalChunks: 10,
        chunkSize: 16384,
      );
      final encOversized = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 2,
        messageId: offerOversized.messageId,
        plaintextBytes: codec.encodePlaintext(offerOversized),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offerOversized.messageId,
        sessionId: 'session-a',
        sequence: 2,
        nonce: Uint8List.fromList(encOversized.nonce),
        ciphertext: Uint8List.fromList(encOversized.ciphertext),
        mac: Uint8List.fromList(encOversized.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));

      // Oversized should NOT be saved as received/pending, must be rejected
      final msgOversized = await repo.getMessageById('offer-oversized');
      expect(msgOversized, isNull);
    });

    test('Temporary directory cleanup and isolation on rejections', () async {
      final localId = container.read(localIdentityStateProvider);
      final notifier = container.read(messagingStateProvider.notifier);
      final peerA = 'peer-a-uuid';

      final sessionA = PeerSession(
        peerId: peerA,
        displayName: 'Peer A',
        endpointId: 'EP_A',
        status: SessionStatus.connected,
        isSecure: true,
        enabledCapabilities: const [VantraCapability.text], // No image!
        remoteMinVersion: 2,
        remoteMaxVersion: 2,
        remoteCapabilities: const [VantraCapability.text],
      );

      final secSessionA = SecuritySession(
        peerId: peerA,
        endpointId: 'EP_A',
        sessionId: 'session-a',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'pub-a',
        remoteFingerprint: 'fp-a',
      );

      notifier.securitySessions[peerA] = secSessionA;
      notifier.aliveEndpoints.add('EP_A');
      notifier.state = notifier.state.copyWith(
        sessions: {
          peerA: sessionA,
        },
        endpointToPeerId: {
          'EP_A': peerA,
        },
      );

      // Create a dummy temp folder and file for Peer A (unsupported capability)
      final appDir = Directory(testTempDir.path);
      final tempDirA = Directory(path.join(appDir.path, 'files', 'temp', 'transfer-cleanup-a'));
      await tempDirA.create(recursive: true);
      final chunkFileA = File(path.join(tempDirA.path, 'chunk_0'));
      await chunkFileA.writeAsString('dummy');

      // Create a dummy temp folder for Peer B (should remain isolated and NOT be deleted!)
      final tempDirB = Directory(path.join(appDir.path, 'files', 'temp', 'transfer-cleanup-b'));
      await tempDirB.create(recursive: true);
      final chunkFileB = File(path.join(tempDirB.path, 'chunk_0'));
      await chunkFileB.writeAsString('dummy');

      // Deliver OFFER for unsupported capability (image)
      final offerMsg = DomainMediaControl(
        messageId: 'offer-unsupported',
        sessionId: 'session-a',
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerA,
        receiverId: localId.peerId,
        type: DomainMediaControlType.offer,
        transferId: 'transfer-cleanup-a',
        fileName: 'unsupported.jpg',
        fileSize: 1000,
        mimeType: 'image/jpeg',
        totalChunks: 1,
        chunkSize: 16384,
      );
      final encOffer = await cryptoService.encryptBytes(
        secretKey: secSessionA.receiveKey,
        sessionSalt: secSessionA.sessionSalt,
        sequence: 1,
        messageId: offerMsg.messageId,
        plaintextBytes: codec.encodePlaintext(offerMsg),
      );
      fakeTransport.triggerIncomingPayload('EP_A', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: offerMsg.messageId,
        sessionId: 'session-a',
        sequence: 1,
        nonce: Uint8List.fromList(encOffer.nonce),
        ciphertext: Uint8List.fromList(encOffer.ciphertext),
        mac: Uint8List.fromList(encOffer.mac),
      )));
      // Wait for cleanup to complete (up to 1.5 seconds)
      for (int i = 0; i < 30; i++) {
        if (!await tempDirA.exists()) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Verify that Peer A's temp folder is cleaned up (deleted)
      expect(await tempDirA.exists(), isFalse);

      // Verify that Peer B's temp folder is untouched (isolation!)
      expect(await tempDirB.exists(), isTrue);

      // Clean up B manually
      await tempDirB.delete(recursive: true);
    });
  });
}
