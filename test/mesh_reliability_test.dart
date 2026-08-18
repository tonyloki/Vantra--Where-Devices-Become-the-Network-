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
import 'package:vantra/core/peers/peer_provider.dart';
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
  final cryptoService = CryptoService();

  group('Vantra V2 Mesh Reliability & Management Integration Tests', () {
    late MockMeshTransport transportA;
    late MockMeshTransport transportB;
    late MockMeshTransport transportC;
    late MockMeshTransport transportD;

    late AppDatabase dbA;
    late AppDatabase dbB;
    late AppDatabase dbC;
    late AppDatabase dbD;

    late ProviderContainer containerA;
    late ProviderContainer containerB;
    late ProviderContainer containerC;
    late ProviderContainer containerD;

    late Directory testTempDir;

    late LocalIdentity identityA;
    late LocalIdentity identityB;
    late LocalIdentity identityC;
    late LocalIdentity identityD;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      testTempDir = Directory.systemTemp.createTempSync('vantra_reliability_test_');

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
      transportD = MockMeshTransport('EP_D');

      dbA = AppDatabase.forTesting(NativeDatabase.memory());
      dbB = AppDatabase.forTesting(NativeDatabase.memory());
      dbC = AppDatabase.forTesting(NativeDatabase.memory());
      dbD = AppDatabase.forTesting(NativeDatabase.memory());

      // Pre-generating unique identities
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

      final keyPairD = await cryptoService.generateIdentityKeyPair();
      final pubKeyD = await keyPairD.extractPublicKey();
      identityD = LocalIdentity(
        peerId: 'peer-d-uuid',
        displayName: 'Device D',
        identityPublicKey: pubKeyD.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        fingerprint: await cryptoService.computeFingerprint(pubKeyD.bytes),
        keyPair: keyPairD,
      );

      // Bridging diamond topology: A <-> B <-> C and A <-> D <-> C
      transportA.onSend = (endpointId, data) {
        if (endpointId == 'EP_A_B') {
          transportB.triggerIncomingPayload('EP_B_A', data);
        } else if (endpointId == 'EP_A_D') {
          transportD.triggerIncomingPayload('EP_D_A', data);
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
        } else if (endpointId == 'EP_C_D') {
          transportD.triggerIncomingPayload('EP_D_C', data);
        }
      };

      transportD.onSend = (endpointId, data) {
        if (endpointId == 'EP_D_A') {
          transportA.triggerIncomingPayload('EP_A_D', data);
        } else if (endpointId == 'EP_D_C') {
          transportC.triggerIncomingPayload('EP_C_D', data);
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

      containerD = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(transportD),
          appDatabaseProvider.overrideWithValue(dbD),
          secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
          localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityD)),
        ],
      );

      await containerA.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
      await containerB.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
      await containerC.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
      await containerD.read(localIdentityStateProvider.notifier).ensureKeysLoaded();

      containerA.read(messagingStateProvider);
      containerB.read(messagingStateProvider);
      containerC.read(messagingStateProvider);
      containerD.read(messagingStateProvider);
    });

    tearDown(() async {
      containerA.dispose();
      containerB.dispose();
      containerC.dispose();
      containerD.dispose();
      await dbA.close();
      await dbB.close();
      await dbC.close();
      await dbD.close();
      if (testTempDir.existsSync()) {
        try {
          testTempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Future<void> establishDiamondConnections() async {
      final repoA = containerA.read(messagingRepositoryProvider);
      final repoB = containerB.read(messagingRepositoryProvider);
      final repoC = containerC.read(messagingRepositoryProvider);
      final repoD = containerD.read(messagingRepositoryProvider);

      // Save credentials in each DB
      await repoA.upsertPeer(identityB.peerId, 'Device B', publicKey: identityB.identityPublicKey, fingerprint: identityB.fingerprint, trustState: PeerTrustState.trusted);
      await repoA.upsertPeer(identityD.peerId, 'Device D', publicKey: identityD.identityPublicKey, fingerprint: identityD.fingerprint, trustState: PeerTrustState.trusted);
      await repoA.upsertPeer(identityC.peerId, 'Device C', publicKey: identityC.identityPublicKey, fingerprint: identityC.fingerprint, trustState: PeerTrustState.trusted);

      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);
      await repoB.upsertPeer(identityC.peerId, 'Device C', publicKey: identityC.identityPublicKey, fingerprint: identityC.fingerprint, trustState: PeerTrustState.trusted);

      await repoC.upsertPeer(identityB.peerId, 'Device B', publicKey: identityB.identityPublicKey, fingerprint: identityB.fingerprint, trustState: PeerTrustState.trusted);
      await repoC.upsertPeer(identityD.peerId, 'Device D', publicKey: identityD.identityPublicKey, fingerprint: identityD.fingerprint, trustState: PeerTrustState.trusted);
      await repoC.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      await repoD.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);
      await repoD.upsertPeer(identityC.peerId, 'Device C', publicKey: identityC.identityPublicKey, fingerprint: identityC.fingerprint, trustState: PeerTrustState.trusted);

      // Connection updates A <-> B
      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));

      // Connection updates B <-> C
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_C', status: ConnectionStatus.connected, endpointName: 'Device C:${identityC.peerId}'));
      transportC.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_C_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));

      // Connection updates A <-> D
      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_D', status: ConnectionStatus.connected, endpointName: 'Device D:${identityD.peerId}'));
      transportD.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_D_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));

      // Connection updates D <-> C
      transportD.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_D_C', status: ConnectionStatus.connected, endpointName: 'Device C:${identityC.peerId}'));
      transportC.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_C_D', status: ConnectionStatus.connected, endpointName: 'Device D:${identityD.peerId}'));

      // Allow handshakes to complete
      await Future.delayed(const Duration(milliseconds: 1500));
    }

    test('Local link failure invalidates route and resets E2E session', () async {
      await establishDiamondConnections();

      // Trigger multi-hop route discovery: A wants to send to C
      await containerA.read(messagingStateProvider.notifier).sendTextMessage(identityC.peerId, 'Hello C');
      await Future.delayed(const Duration(milliseconds: 500));

      // Route should be active via B (first discovery wins or lower alphabetical/etc.)
      final stateA = containerA.read(messagingStateProvider);
      final initialRoute = containerA.read(messagingStateProvider.notifier).debugGetRoute(identityC.peerId);
      expect(initialRoute, isNotNull);
      expect(initialRoute!.isActive, isTrue);

      final viaEndpoint = initialRoute.nextHopEndpointId;

      // Disconnect that link locally on A
      transportA.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: viaEndpoint,
        status: ConnectionStatus.disconnected,
        endpointName: 'Device',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // The route via that endpoint must now be marked inactive
      final routeAfterDisconnect = containerA.read(messagingStateProvider.notifier).debugGetRoute(identityC.peerId);
      expect(routeAfterDisconnect!.isActive, isFalse);

      // Security session for C should be reset (no longer secure)
      final sessionC = containerA.read(messagingStateProvider).sessions[identityC.peerId];
      expect(sessionC == null || !sessionC.isSecure, isTrue);
    });

    test('Dynamic Trusted/Blocked stream providers read reactive database updates', () async {
      final repoA = containerA.read(messagingRepositoryProvider);
      final notifierA = containerA.read(messagingStateProvider.notifier);

      // Listen to keep provider active
      containerA.listen(trustedPeersStreamProvider, (_, __) {});
      containerA.listen(blockedPeersStreamProvider, (_, __) {});

      // Save a peer untrusted
      await repoA.upsertPeer('peer-test', 'Tester', trustState: PeerTrustState.untrusted);
      await Future.delayed(const Duration(milliseconds: 100));

      // Ensure lists are empty initially
      var trusted = containerA.read(trustedPeersStreamProvider).value ?? [];
      var blocked = containerA.read(blockedPeersStreamProvider).value ?? [];
      expect(trusted.any((p) => p.peerId == 'peer-test'), isFalse);
      expect(blocked.any((p) => p.peerId == 'peer-test'), isFalse);

      // Toggle trust state to Trusted
      await notifierA.setPeerTrustState('peer-test', PeerTrustState.trusted);
      await Future.delayed(const Duration(milliseconds: 100));

      trusted = containerA.read(trustedPeersStreamProvider).value ?? [];
      expect(trusted.any((p) => p.peerId == 'peer-test'), isTrue);

      // Toggle trust state to Blocked (distrusted)
      await notifierA.blockPeer('peer-test');
      await Future.delayed(const Duration(milliseconds: 100));

      trusted = containerA.read(trustedPeersStreamProvider).value ?? [];
      blocked = containerA.read(blockedPeersStreamProvider).value ?? [];
      expect(trusted.any((p) => p.peerId == 'peer-test'), isFalse);
      expect(blocked.any((p) => p.peerId == 'peer-test'), isTrue);
    });

    test('Delete message, clear chat, and delete contact clean up UI & database', () async {
      final repoA = containerA.read(messagingRepositoryProvider);
      final notifierA = containerA.read(messagingStateProvider.notifier);

      // Save a peer & insert some messages
      await repoA.upsertPeer('peer-mngr', 'Manager', trustState: PeerTrustState.trusted);
      final msg1 = VantraMessage(
        messageId: 'msg-1',
        senderId: identityA.peerId,
        receiverId: 'peer-mngr',
        text: 'Hello',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.delivered,
      );
      final msg2 = VantraMessage(
        messageId: 'msg-2',
        senderId: 'peer-mngr',
        receiverId: identityA.peerId,
        text: 'Hi',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.received,
      );
      await repoA.saveOutgoingMessage(msg1);
      await repoA.saveIncomingMessage(msg2);

      // Verify messages exist in DB
      var history = await repoA.getConversation(identityA.peerId, 'peer-mngr');
      expect(history.length, 2);

      // Delete individual message msg-1
      await notifierA.deleteMessage('msg-1');
      await Future.delayed(const Duration(milliseconds: 50));
      history = await repoA.getConversation(identityA.peerId, 'peer-mngr');
      expect(history.length, 1);
      expect(history.first.messageId, 'msg-2');

      // Clear chat
      await notifierA.clearChat('peer-mngr');
      await Future.delayed(const Duration(milliseconds: 50));
      history = await repoA.getConversation(identityA.peerId, 'peer-mngr');
      expect(history.isEmpty, isTrue);

      // Add a message again to test contact delete cascade
      await repoA.saveIncomingMessage(msg2);
      history = await repoA.getConversation(identityA.peerId, 'peer-mngr');
      expect(history.length, 1);

      // Delete contact
      await notifierA.deleteContact('peer-mngr');
      await Future.delayed(const Duration(milliseconds: 50));

      final peer = await repoA.getPeer('peer-mngr');
      expect(peer, isNull);

      history = await repoA.getConversation(identityA.peerId, 'peer-mngr');
      expect(history.isEmpty, isTrue);
    });
  });
}

extension on MessagingNotifier {
  RouteEntry? debugGetRoute(String destPeerId) => routingTable[destPeerId];
}
