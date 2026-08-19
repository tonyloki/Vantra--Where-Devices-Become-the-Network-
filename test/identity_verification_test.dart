import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/security/safety_number_service.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/messaging/messaging_repository.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'test_fakes.dart';

void main() {
  group('SafetyNumberService Tests', () {
    const keyA = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const keyB = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    const keyC = '1111111111111111111111111111111111111111111111111111111111111111';

    test('Safety Number is deterministic and commutative', () {
      final num1 = SafetyNumberService.computeSafetyNumber(keyA, keyB);
      final num2 = SafetyNumberService.computeSafetyNumber(keyB, keyA);

      expect(num1, equals(num2));
      expect(num1, isNotEmpty);
    });

    test('Safety Number format is 25 digits (5 groups of 5)', () {
      final num = SafetyNumberService.computeSafetyNumber(keyA, keyB);
      // Format: XXXXX XXXXX XXXXX XXXXX XXXXX
      final parts = num.split(' ');
      expect(parts.length, equals(5));
      for (var part in parts) {
        expect(part.length, equals(5));
        expect(int.tryParse(part), isNotNull);
      }
    });

    test('Safety Number changes when either key changes', () {
      final numAB = SafetyNumberService.computeSafetyNumber(keyA, keyB);
      final numAC = SafetyNumberService.computeSafetyNumber(keyA, keyC);
      final numBC = SafetyNumberService.computeSafetyNumber(keyB, keyC);

      expect(numAB, isNot(equals(numAC)));
      expect(numAB, isNot(equals(numBC)));
    });
  });

  group('Database Peer Verification Tests', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('updatePeerVerification stores verifiedPublicKey and marks verified', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final peer = Peer(
        peerId: 'peer-1',
        displayName: 'Peer A',
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
        trustState: PeerTrustState.untrusted,
      );

      await db.peerDao.insertOrUpdatePeer(peer);

      var fetched = await db.peerDao.getPeer('peer-1');
      expect(fetched!.trustState, equals(PeerTrustState.untrusted));
      expect(fetched.verifiedPublicKey, isNull);

      // Verify the peer
      const verifiedKey = 'verified-key-hex';
      await db.peerDao.updatePeerVerification('peer-1', verifiedKey);

      fetched = await db.peerDao.getPeer('peer-1');
      expect(fetched!.trustState, equals(PeerTrustState.verified));
      expect(fetched.verifiedPublicKey, equals(verifiedKey));
    });
  });

  group('MITM Guard Handshake Integration Tests', () {
    late AppDatabase db;
    late ProviderContainer container;
    late FakeTransport fakeTransport;
    late MessagingRepository repo;
    late CryptoService cryptoService;
    const codec = ProtobufCodec();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = MessagingRepository(db);
      fakeTransport = FakeTransport();
      cryptoService = CryptoService();

      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          messagingRepositoryProvider.overrideWithValue(repo),
          transportProvider.overrideWithValue(fakeTransport),
        ],
      );

      // Wait for local identity to initialize
      await container.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('Connection succeeded if peer is verified and public key matches', () async {
      final notifier = container.read(messagingStateProvider.notifier);

      const peerId = 'verified-peer-id';
      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteIdPubHex = remoteIdPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // 1. Setup peer as VERIFIED in DB with remoteIdPubHex
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.peerDao.insertOrUpdatePeer(Peer(
        peerId: peerId,
        displayName: 'Alice',
        publicKey: remoteIdPubHex,
        trustState: PeerTrustState.verified,
        verifiedPublicKey: remoteIdPubHex,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      ));

      // 2. Trigger connection connected
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'EP_ALICE',
        endpointName: 'Alice',
        status: ConnectionStatus.connected,
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();

      final signatureBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'Alice',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final payload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'Alice',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(signatureBytes),
      );

      // 3. Trigger incoming handshake payload
      fakeTransport.triggerIncomingPayload('EP_ALICE', codec.encodeWireEnvelope(payload));
      await Future.delayed(const Duration(milliseconds: 50));

      // 4. Verify secure session is successfully established
      final session = notifier.state.sessions[peerId];
      expect(session, isNotNull);
      expect(session?.status, equals(SessionStatus.connected));
      expect(session?.isSecure, isTrue);
      expect(notifier.state.identityMismatchRequest, isNull);
    });

    test('Connection rejected and IdentityMismatchRequest set if peer is verified and public key mismatches', () async {
      final notifier = container.read(messagingStateProvider.notifier);

      const peerId = 'verified-peer-id';
      const originalVerifiedKey = '1111111111111111111111111111111111111111111111111111111111111111';

      // 1. Setup peer as VERIFIED in DB with originalVerifiedKey
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.peerDao.insertOrUpdatePeer(Peer(
        peerId: peerId,
        displayName: 'Alice',
        publicKey: originalVerifiedKey,
        trustState: PeerTrustState.verified,
        verifiedPublicKey: originalVerifiedKey,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      ));

      // 2. Trigger connection connected
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'EP_ALICE',
        endpointName: 'Alice',
        status: ConnectionStatus.connected,
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // Generate a DIFFERENT keypair representing the malicious MITM peer
      final maliciousIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final maliciousIdPub = await maliciousIdentityKeyPair.extractPublicKey();

      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();

      final signatureBytes = await cryptoService.signHandshake(
        identityKeyPair: maliciousIdentityKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'Alice',
        identityPublicKeyBytes: maliciousIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final payload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'Alice',
        identityPublicKey: Uint8List.fromList(maliciousIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(signatureBytes),
      );

      // 3. Trigger incoming handshake payload (MITM key)
      fakeTransport.triggerIncomingPayload('EP_ALICE', codec.encodeWireEnvelope(payload));
      await Future.delayed(const Duration(milliseconds: 50));

      // 4. Verify session is not connected, transport disconnect called, and mismatch set
      final session = notifier.state.sessions[peerId];
      expect(session?.status ?? SessionStatus.disconnected, isNot(equals(SessionStatus.connected)));
      expect(fakeTransport.disconnectCalled, isTrue);
      expect(fakeTransport.disconnectedTarget, equals('EP_ALICE'));

      final mismatch = notifier.state.identityMismatchRequest;
      expect(mismatch, isNotNull);
      expect(mismatch?.peerId, equals(peerId));
      expect(mismatch?.oldPublicKey, equals(originalVerifiedKey));
      final maliciousHex = maliciousIdPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(mismatch?.newPublicKey, equals(maliciousHex));
    });

    test('Connection succeeds and trustState remains untrusted if peer is NOT verified even if public key changes', () async {
      final notifier = container.read(messagingStateProvider.notifier);

      const peerId = 'unverified-peer-id';
      const originalKey = '1111111111111111111111111111111111111111111111111111111111111111';

      // 1. Setup peer as untrusted (TOFU) in DB
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.peerDao.insertOrUpdatePeer(Peer(
        peerId: peerId,
        displayName: 'Alice',
        publicKey: originalKey,
        trustState: PeerTrustState.untrusted,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      ));

      // 2. Trigger connection connected
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'EP_ALICE',
        endpointName: 'Alice',
        status: ConnectionStatus.connected,
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // Generate a DIFFERENT keypair representing changed key
      final newIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final newIdPub = await newIdentityKeyPair.extractPublicKey();

      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();

      final signatureBytes = await cryptoService.signHandshake(
        identityKeyPair: newIdentityKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'Alice',
        identityPublicKeyBytes: newIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final payload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'Alice',
        identityPublicKey: Uint8List.fromList(newIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(signatureBytes),
      );

      // 3. Trigger incoming handshake payload (new key)
      fakeTransport.triggerIncomingPayload('EP_ALICE', codec.encodeWireEnvelope(payload));
      await Future.delayed(const Duration(milliseconds: 50));

      // 4. Verify secure session is successfully established (unverified peer has TOFU behavior)
      final session = notifier.state.sessions[peerId];
      expect(session, isNotNull);
      expect(session?.status, equals(SessionStatus.connected));
      expect(session?.isSecure, isTrue);
      expect(notifier.state.identityMismatchRequest, isNull);
    });
  });
}
