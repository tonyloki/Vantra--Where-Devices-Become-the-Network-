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

  Future<DomainHandshakePayload> createRemoteHandshake(String remotePeerId, String displayName) async {
    final idKeyPair = await cryptoService.generateIdentityKeyPair();
    final ephKeyPair = await cryptoService.generateEphemeralKeyPair();

    final idPub = await idKeyPair.extractPublicKey();
    final ephPub = await ephKeyPair.extractPublicKey();

    final sigBytes = await cryptoService.signHandshake(
      identityKeyPair: idKeyPair,
      protocolVersion: kCurrentProtocolVersion,
      peerId: remotePeerId,
      displayName: displayName,
      identityPublicKeyBytes: idPub.bytes,
      ephemeralPublicKeyBytes: ephPub.bytes,
    );

    return DomainHandshakePayload(
      protocolVersion: kCurrentProtocolVersion,
      peerId: remotePeerId,
      displayName: displayName,
      identityPublicKey: Uint8List.fromList(idPub.bytes),
      ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
      signature: Uint8List.fromList(sigBytes),
    );
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

      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(remotePayload));
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
      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(remotePayload));
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
      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(remotePayload));
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
