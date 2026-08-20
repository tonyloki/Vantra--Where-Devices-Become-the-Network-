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

class MockMeshTransport extends FakeTransport {
  final String localEndpoint;
  Function(String endpointId, Uint8List data)? onSend;

  MockMeshTransport(this.localEndpoint);

  @override
  Future<void> send(String endpointId, Uint8List data) async {
    await super.send(endpointId, data);
    if (onSend != null) {
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

  group('Vantra V2 Mesh Features Integration Tests', () {
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
      testTempDir = Directory.systemTemp.createTempSync('vantra_mesh_features_');

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

    test('Create Group, Invite Members, and Send Group Message over Mesh Routing: A -> B -> C', () async {
      final peerA = identityA.peerId;
      final peerB = identityB.peerId;
      final peerC = identityC.peerId;

      final pubA = identityA.identityPublicKey;
      final pubB = identityB.identityPublicKey;
      final pubC = identityC.identityPublicKey;

      final fpA = identityA.fingerprint;
      final fpB = identityB.fingerprint;
      final fpC = identityC.fingerprint;

      // Populating database peers
      final repoA = containerA.read(messagingRepositoryProvider);
      await repoA.upsertPeer(peerB, 'Device B', publicKey: pubB, fingerprint: fpB, trustState: PeerTrustState.trusted, protocolVersion: 2);
      await repoA.upsertPeer(peerC, 'Device C', publicKey: pubC, fingerprint: fpC, trustState: PeerTrustState.trusted, protocolVersion: 2);

      final repoB = containerB.read(messagingRepositoryProvider);
      await repoB.upsertPeer(peerA, 'Device A', publicKey: pubA, fingerprint: fpA, trustState: PeerTrustState.trusted, protocolVersion: 2);
      await repoB.upsertPeer(peerC, 'Device C', publicKey: pubC, fingerprint: fpC, trustState: PeerTrustState.trusted, protocolVersion: 2);

      final repoC = containerC.read(messagingRepositoryProvider);
      await repoC.upsertPeer(peerA, 'Device A', publicKey: pubA, fingerprint: fpA, trustState: PeerTrustState.trusted, protocolVersion: 2);
      await repoC.upsertPeer(peerB, 'Device B', publicKey: pubB, fingerprint: fpB, trustState: PeerTrustState.trusted, protocolVersion: 2);

      // Establish link A <-> B
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
      await Future.delayed(const Duration(milliseconds: 1000));

      // Establish link B <-> C
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
      await Future.delayed(const Duration(milliseconds: 1000));

      // Route discovery to C from A
      final notifierA = containerA.read(messagingStateProvider.notifier);
      await notifierA.sendTextMessage(peerC, 'establishing route');
      await Future.delayed(const Duration(milliseconds: 1500));

      // Check route exists
      final routingA = notifierA.routingTable;
      expect(routingA[peerC], isNotNull);

      // 1. Create a group on A including B and C (routed over mesh)
      await notifierA.createAndInviteGroup('Mesh Security Team', [peerB, peerC]);

      final groupsInA = await dbA.groupDao.select(dbA.groups).get();
      expect(groupsInA.isNotEmpty, isTrue);
      final groupId = groupsInA.first.groupId;

      // Wait for group invite propagation (A -> C via mesh)
      await Future.delayed(const Duration(milliseconds: 1500));

      // Verify C received the group invite and saved the group locally
      final groupInC = await repoC.getGroup(groupId);
      expect(groupInC, isNotNull);
      expect(groupInC!.name, 'Mesh Security Team');

      // 2. Send group message from A
      await notifierA.sendGroupMessage(groupId, 'Welcome to the secure mesh channel!');
      await Future.delayed(const Duration(milliseconds: 1500));

      // Verify B received the group message (direct)
      final msgsInB = await (dbB.select(dbB.messages)..where((t) => t.groupId.equals(groupId))).get();
      expect(msgsInB.isNotEmpty, isTrue);
      expect(msgsInB.first.messageText, 'Welcome to the secure mesh channel!');

      // Verify C received the group message (over mesh)
      final msgsInC = await (dbC.select(dbC.messages)..where((t) => t.groupId.equals(groupId))).get();
      expect(msgsInC.isNotEmpty, isTrue);
      expect(msgsInC.first.messageText, 'Welcome to the secure mesh channel!');
    });
  });
}
