import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';

import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/identity/local_identity.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/messaging/messaging_repository.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'test_fakes.dart';

// Class name does NOT contain 'Fake', which enables the production 500ms handshake delay,
// avoiding race conditions between simultaneous connection updates.
class MockMeshTransport extends FakeTransport {
  final String localEndpoint;
  Function(String endpointId, Uint8List data)? onSend;

  MockMeshTransport(this.localEndpoint);

  @override
  Future<void> send(String endpointId, Uint8List data) async {
    await super.send(endpointId, data);
    if (onSend != null) {
      // Deliver asynchronously to simulate real network latency and prevent event-loop race conditions
      Future.delayed(const Duration(milliseconds: 20), () {
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
  LocalIdentity build() {
    return presetIdentity;
  }

  @override
  Future<void> ensureKeysLoaded() async {
    state = presetIdentity;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = ProtobufCodec();
  final cryptoService = CryptoService();

  group('Vantra V2 Mesh Routing Integration Tests', () {
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
      testTempDir = Directory.systemTemp.createTempSync('vantra_mesh_test_');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'getApplicationDocumentsDirectory') {
            return testTempDir.path;
          }
          return null;
        },
      );

      transportA = MockMeshTransport('EP_A');
      transportB = MockMeshTransport('EP_B');
      transportC = MockMeshTransport('EP_C');

      dbA = AppDatabase.forTesting(NativeDatabase.memory());
      dbB = AppDatabase.forTesting(NativeDatabase.memory());
      dbC = AppDatabase.forTesting(NativeDatabase.memory());

      // Pre-generating unique identities for each container
      final keyPairA = await cryptoService.generateIdentityKeyPair();
      final pubKeyA = await keyPairA.extractPublicKey();
      final pubKeyHexA = pubKeyA.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fpA = await cryptoService.computeFingerprint(pubKeyA.bytes);
      identityA = LocalIdentity(
        peerId: 'peer-a-uuid',
        displayName: 'Device A',
        identityPublicKey: pubKeyHexA,
        fingerprint: fpA,
        keyPair: keyPairA,
      );

      final keyPairB = await cryptoService.generateIdentityKeyPair();
      final pubKeyB = await keyPairB.extractPublicKey();
      final pubKeyHexB = pubKeyB.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fpB = await cryptoService.computeFingerprint(pubKeyB.bytes);
      identityB = LocalIdentity(
        peerId: 'peer-b-uuid',
        displayName: 'Device B',
        identityPublicKey: pubKeyHexB,
        fingerprint: fpB,
        keyPair: keyPairB,
      );

      final keyPairC = await cryptoService.generateIdentityKeyPair();
      final pubKeyC = await keyPairC.extractPublicKey();
      final pubKeyHexC = pubKeyC.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fpC = await cryptoService.computeFingerprint(pubKeyC.bytes);
      identityC = LocalIdentity(
        peerId: 'peer-c-uuid',
        displayName: 'Device C',
        identityPublicKey: pubKeyHexC,
        fingerprint: fpC,
        keyPair: keyPairC,
      );

      // Bridging transport network A <-> B <-> C
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

      // Containers setup
      final prefs = await SharedPreferences.getInstance();

      containerA = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(transportA),
          appDatabaseProvider.overrideWithValue(dbA),
          secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
          localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityA)),
        ],
      );

      containerB = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(transportB),
          appDatabaseProvider.overrideWithValue(dbB),
          secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
          localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityB)),
        ],
      );

      containerC = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(transportC),
          appDatabaseProvider.overrideWithValue(dbC),
          secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
          localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityC)),
        ],
      );

      await containerA.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
      await containerB.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
      await containerC.read(localIdentityStateProvider.notifier).ensureKeysLoaded();

      // Force lazy providers to instantiate so that they register their listeners
      containerA.read(messagingStateProvider);
      containerB.read(messagingStateProvider);
      containerC.read(messagingStateProvider);
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

    test('Full Multi-Hop Route Discovery, E2E Handshake, and Text Transmission: A -> B -> C', () async {
      final peerA = identityA.peerId;
      final peerB = identityB.peerId;
      final peerC = identityC.peerId;

      final pubA = identityA.identityPublicKey;
      final pubB = identityB.identityPublicKey;
      final pubC = identityC.identityPublicKey;

      final fpA = identityA.fingerprint;
      final fpB = identityB.fingerprint;
      final fpC = identityC.fingerprint;

      // Populating public keys in databases
      // A's DB: knows B and C
      final repoA = containerA.read(messagingRepositoryProvider);
      await repoA.upsertPeer(peerB, 'Device B', publicKey: pubB, fingerprint: fpB, trustState: PeerTrustState.trusted, protocolVersion: 2);
      await repoA.upsertPeer(peerC, 'Device C', publicKey: pubC, fingerprint: fpC, trustState: PeerTrustState.trusted, protocolVersion: 2);

      // B's DB: knows A and C
      final repoB = containerB.read(messagingRepositoryProvider);
      await repoB.upsertPeer(peerA, 'Device A', publicKey: pubA, fingerprint: fpA, trustState: PeerTrustState.trusted, protocolVersion: 2);
      await repoB.upsertPeer(peerC, 'Device C', publicKey: pubC, fingerprint: fpC, trustState: PeerTrustState.trusted, protocolVersion: 2);

      // C's DB: knows A and B
      final repoC = containerC.read(messagingRepositoryProvider);
      await repoC.upsertPeer(peerA, 'Device A', publicKey: pubA, fingerprint: fpA, trustState: PeerTrustState.trusted, protocolVersion: 2);
      await repoC.upsertPeer(peerB, 'Device B', publicKey: pubB, fingerprint: fpB, trustState: PeerTrustState.trusted, protocolVersion: 2);

      // 2. Establish direct connection A <-> B
      transportA.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_A_B',
        status: ConnectionStatus.connected,
        endpointName: 'Device B:$peerB',
      ));
      transportB.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_B_A',
        status: ConnectionStatus.connected,
        endpointName: 'Device A:$peerA',
      ));

      // Wait 1.5s for direct handshake A <-> B to complete (including 500ms delay + 20ms network delay)
      await Future.delayed(const Duration(milliseconds: 1500));

      // 3. Establish direct connection B <-> C
      transportB.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_B_C',
        status: ConnectionStatus.connected,
        endpointName: 'Device C:$peerC',
      ));
      transportC.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_C_B',
        status: ConnectionStatus.connected,
        endpointName: 'Device B:$peerB',
      ));

      // Wait 1.5s for direct handshake B <-> C to complete (including 500ms delay + 20ms network delay)
      await Future.delayed(const Duration(milliseconds: 1500));

      // Verify that direct links are secure
      final stateA = containerA.read(messagingStateProvider);
      final stateB = containerB.read(messagingStateProvider);
      final stateC = containerC.read(messagingStateProvider);

      expect(stateA.sessions[peerB]?.isSecure, isTrue);
      expect(stateB.sessions[peerA]?.isSecure, isTrue);
      expect(stateB.sessions[peerC]?.isSecure, isTrue);
      expect(stateC.sessions[peerB]?.isSecure, isTrue);

      // Verify A and C have no direct connection
      expect(stateA.sessions[peerC], isNull);
      expect(stateC.sessions[peerA], isNull);

      // 4. Send message from A to C (triggering route discovery, handshake, then sending message)
      await containerA.read(messagingStateProvider.notifier).sendTextMessage(
        peerC,
        'Hello multi-hop mesh!',
      );

      // Wait for route discovery and handshake to complete automatically
      await Future.delayed(const Duration(milliseconds: 2000));

      // Get the message ID from the conversation list
      final msgsInA = await repoA.getConversation(peerA, peerC);
      expect(msgsInA.isNotEmpty, isTrue);
      final messageId = msgsInA.first.messageId;

      // 5. Verify routing table entries
      final routingA = containerA.read(messagingStateProvider.notifier).routingTable;
      final routingC = containerC.read(messagingStateProvider.notifier).routingTable;

      expect(routingA[peerC], isNotNull);
      expect(routingA[peerC]!.nextHopPeerId, peerB);
      expect(routingA[peerC]!.hopCount, 2);

      expect(routingC[peerA], isNotNull);
      expect(routingC[peerA]!.nextHopPeerId, peerB);
      expect(routingC[peerA]!.hopCount, 2);

      // 6. Verify session is now secure between A & C
      final finalStateA = containerA.read(messagingStateProvider);
      final finalStateC = containerC.read(messagingStateProvider);

      expect(finalStateA.sessions[peerC]?.isSecure, isTrue);
      expect(finalStateC.sessions[peerA]?.isSecure, isTrue);

      // 7. Verify message delivery in C's DB
      final msgInC = await repoC.getMessageById(messageId);
      expect(msgInC, isNotNull);
      expect(msgInC!.text, 'Hello multi-hop mesh!');
      expect(msgInC.senderId, peerA);
      expect(msgInC.receiverId, peerC);

      // 8. Verify message status updated to delivered in A's DB
      final msgInA = await repoA.getMessageById(messageId);
      expect(msgInA, isNotNull);
      expect(msgInA!.status, MessageStatus.delivered);
    });
  });
}
