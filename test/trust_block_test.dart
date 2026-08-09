import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
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

  group('Blocking & Trust Security Invariant Tests', () {
    test('BLOCKING INVARIANT: Blocked peer connection is immediately rejected and disconnected on handshake', () async {
      container.read(messagingStateProvider);

      final blockedPeerId = const Uuid().v4();
      final repo = container.read(messagingRepositoryProvider);

      // Pre-block the peer in database
      await repo.upsertPeer(
        blockedPeerId,
        'AttackerPeer',
        trustState: PeerTrustState.distrusted,
      );

      // Trigger transport connection from blocked peer
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'BLOCKED_EP',
        status: ConnectionStatus.connected,
        endpointName: 'BLOCKED_EP',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // Blocked peer attempts to send valid signed IDENTITY_SECURE handshake
      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: blockedPeerId,
        displayName: 'AttackerPeer',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final handshakePayload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: blockedPeerId,
        displayName: 'AttackerPeer',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('BLOCKED_EP', codec.encodeWireEnvelope(handshakePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      // INVARIANT 1: Transport disconnect was immediately called
      expect(fakeTransport.disconnectCalled, isTrue);
      expect(fakeTransport.disconnectedTarget, 'BLOCKED_EP');

      // INVARIANT 2: No secure session was established for blocked peer
      final state = container.read(messagingStateProvider);
      final session = state.sessions[blockedPeerId];
      expect(session?.isSecure ?? false, isFalse);
    });

    test('Blocking an active peer immediately terminates transport connection and session', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      final peerId = const Uuid().v4();

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'ACTIVE_EP',
        status: ConnectionStatus.connected,
        endpointName: 'ACTIVE_EP',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'FriendThenBlocked',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final handshakePayload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'FriendThenBlocked',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('ACTIVE_EP', codec.encodeWireEnvelope(handshakePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      // Connected initially
      var session = container.read(messagingStateProvider).sessions[peerId];
      expect(session?.isSecure, isTrue);

      // Now block peer
      fakeTransport.disconnectCalled = false;
      await notifier.blockPeer(peerId);

      // Verify disconnect called and state updated
      expect(fakeTransport.disconnectCalled, isTrue);
      expect(fakeTransport.disconnectedTarget, 'ACTIVE_EP');

      session = container.read(messagingStateProvider).sessions[peerId];
      expect(session?.status, SessionStatus.disconnected);
      expect(session?.trustState, PeerTrustState.distrusted);
      expect(session?.isSecure, isFalse);

      // Unblocking returns to untrusted without auto-trusting
      await notifier.unblockPeer(peerId);
      session = container.read(messagingStateProvider).sessions[peerId];
      expect(session?.trustState, PeerTrustState.untrusted);
    });
  });
}
