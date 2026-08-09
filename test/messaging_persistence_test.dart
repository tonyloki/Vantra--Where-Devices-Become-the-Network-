import 'dart:convert';
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
import 'package:vantra/core/security/crypto_service.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport fakeTransport;
  late ProviderContainer container;
  late AppDatabase testDb;
  late CryptoService cryptoService;

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

  Future<Map<String, dynamic>> createRemoteHandshake(String remotePeerId, String displayName) async {
    final idKeyPair = await cryptoService.generateIdentityKeyPair();
    final ephKeyPair = await cryptoService.generateEphemeralKeyPair();

    final idPub = await idKeyPair.extractPublicKey();
    final ephPub = await ephKeyPair.extractPublicKey();

    final sigBytes = await cryptoService.signHandshake(
      identityKeyPair: idKeyPair,
      protocolVersion: 1,
      peerId: remotePeerId,
      displayName: displayName,
      identityPublicKeyBytes: idPub.bytes,
      ephemeralPublicKeyBytes: ephPub.bytes,
    );

    return {
      'type': 'IDENTITY_SECURE',
      'v': 1,
      'peerId': remotePeerId,
      'displayName': displayName,
      'identityPublicKey': idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'ephemeralPublicKey': ephPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'signature': sigBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    };
  }

  group('Messaging Pipeline Persistence Tests', () {
    test('Identity handshake updates Peer table with crypto fields and does not create chat messages', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePeerId = const Uuid().v4();
      final remotePayload = await createRemoteHandshake(remotePeerId, 'VantraRemotePeer');

      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      final repo = container.read(messagingRepositoryProvider);
      final dbPeer = await repo.getPeer(remotePeerId);
      expect(dbPeer, isNotNull);
      expect(dbPeer!.displayName, 'VantraRemotePeer');
      expect(dbPeer.lastKnownEndpointId, 'QHZD');
      expect(dbPeer.publicKey, isNotNull);
      expect(dbPeer.fingerprint, isNotNull);

      final localIdentity = container.read(localIdentityStateProvider);
      final messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.isEmpty, isTrue);
    });

    test('Outgoing message is persisted with pending status and becomes sent on success', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePeerId = const Uuid().v4();
      final remotePayload = await createRemoteHandshake(remotePeerId, 'VantraRemote');
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      await notifier.sendTextMessage(remotePeerId, 'Outbound text');

      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.length, 1);
      expect(messages[0].text, 'Outbound text');
      expect(messages[0].status, MessageStatus.sent);
    });

    test('Outgoing message is persisted and becomes failed if transport throws error', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePeerId = const Uuid().v4();
      final remotePayload = await createRemoteHandshake(remotePeerId, 'VantraRemote');
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      fakeTransport.throwErrorOnSend = true;

      try {
        await notifier.sendTextMessage(remotePeerId, 'Outbound error text');
      } catch (_) {}

      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.length, 1);
      expect(messages[0].text, 'Outbound error text');
      expect(messages[0].status, MessageStatus.failed);
    });
  });
}
