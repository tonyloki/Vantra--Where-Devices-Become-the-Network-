import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/messaging/messaging_repository.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = ProtobufCodec();

  group('VantraMessage Serialization Tests', () {
    test('Successful serialization & deserialization', () {
      final msg = VantraMessage(
        messageId: const Uuid().v4(),
        senderId: 'device-a',
        receiverId: 'device-b',
        text: 'Hello Mesh',
        timestamp: 1718000000000,
        status: MessageStatus.sent,
      );

      final json = msg.toJson();
      expect(json['type'], 'TEXT');
      expect(json['text'], 'Hello Mesh');
      expect(json['senderId'], 'device-a');
      expect(json['receiverId'], 'device-b');

      final deserialized = VantraMessage.fromJson(json);
      expect(deserialized.messageId, msg.messageId);
      expect(deserialized.text, msg.text);
      expect(deserialized.senderId, msg.senderId);
      expect(deserialized.receiverId, msg.receiverId);
      expect(deserialized.timestamp, msg.timestamp);
      expect(deserialized.status, MessageStatus.received);
    });

    test('CopyWith retains properties properly', () {
      final msg = VantraMessage(
        messageId: '123',
        senderId: 'a',
        receiverId: 'b',
        text: 'Hello',
        timestamp: 100,
        status: MessageStatus.pending,
      );

      final copy = msg.copyWith(text: 'Updated', status: MessageStatus.sent);
      expect(copy.messageId, '123');
      expect(copy.text, 'Updated');
      expect(copy.status, MessageStatus.sent);
    });
  });

  group('MessagingNotifier & Identity Handshake Tests', () {
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

    test('Loads persistent peerId and displayName from SharedPreferences', () async {
      final localIdentity = container.read(localIdentityStateProvider);
      expect(localIdentity.peerId, isNotEmpty);
      expect(localIdentity.displayName, startsWith('Vantra-'));

      await container.read(localIdentityStateProvider.notifier).updateDisplayName('VantraCustom');
      final updatedIdentity = container.read(localIdentityStateProvider);
      expect(updatedIdentity.displayName, 'VantraCustom');
      expect(updatedIdentity.peerId, localIdentity.peerId);
    });

    test('Identity handshake triggers immediately upon connection', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'RemoteDevice',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(fakeTransport.sentTargets.length, 1);
      expect(fakeTransport.sentTargets[0], 'QHZD');

      final envelope = codec.decodeWireEnvelope(fakeTransport.sentPayloads[0]);
      expect(envelope, isA<DomainHandshakePayload>());
      final handshake = envelope as DomainHandshakePayload;
      expect(handshake.protocolVersion, kCurrentProtocolVersion);
      expect(handshake.signature.isNotEmpty, isTrue);
    });

    test('Identity payload establishes peer session and supports reconnection mapping', () async {
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

      final state = container.read(messagingStateProvider);
      expect(state.sessions[remotePeerId], isNotNull);
      expect(state.sessions[remotePeerId]!.displayName, 'VantraRemote');
      expect(state.sessions[remotePeerId]!.endpointId, 'QHZD');
      expect(state.sessions[remotePeerId]!.status, SessionStatus.connected);
      expect(state.sessions[remotePeerId]!.isSecure, isTrue);

      // Reconnect test: Peer reconnects with a new endpointId 'XVAA'
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'XVAA',
        status: ConnectionStatus.connected,
        endpointName: 'XVAA',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayloadReconnect = await createRemoteHandshake(remotePeerId, 'VantraRemoteUpdated');
      fakeTransport.triggerIncomingPayload('XVAA', codec.encodeWireEnvelope(remotePayloadReconnect));
      await Future.delayed(const Duration(milliseconds: 50));

      final stateAfterReconnect = container.read(messagingStateProvider);
      expect(stateAfterReconnect.sessions[remotePeerId]!.endpointId, 'XVAA');
      expect(stateAfterReconnect.sessions[remotePeerId]!.displayName, 'VantraRemoteUpdated');
      expect(stateAfterReconnect.sessions[remotePeerId]!.status, SessionStatus.connected);
    });

    test('Disconnections update the mapped peer session status', () async {
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

      expect(container.read(messagingStateProvider).sessions[remotePeerId]!.status, SessionStatus.connected);

      // Trigger disconnected update
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.disconnected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(messagingStateProvider).sessions[remotePeerId]!.status, SessionStatus.disconnected);
    });

    test('Sending text message adds to history and throws error if disconnected', () async {
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

      // Send text message successfully
      await notifier.sendTextMessage(remotePeerId, 'Test Message payload');
      
      final localIdentity = container.read(localIdentityStateProvider);
      final MessagingRepository repo = container.read(messagingRepositoryProvider);
      final messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.length, 1);
      expect(messages[0].text, 'Test Message payload');

      // Verify transport payload is encrypted Protobuf envelope
      expect(fakeTransport.sentTargets.length, 2);
      expect(fakeTransport.sentTargets[1], 'QHZD');
      
      final sentEnvelope = codec.decodeWireEnvelope(fakeTransport.sentPayloads[1]);
      expect(sentEnvelope, isA<DomainEncryptedEnvelope>());
      final sentEnc = sentEnvelope as DomainEncryptedEnvelope;
      expect(sentEnc.protocolVersion, kCurrentProtocolVersion);
      expect(sentEnc.ciphertext.isNotEmpty, isTrue);

      // Disconnect and try to send again — should queue locally as pending
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.disconnected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      await notifier.sendTextMessage(remotePeerId, 'Failure test');
      final pendingMsgs = await repo.getPendingOrFailedMessages(remotePeerId);
      expect(pendingMsgs.length, 1);
      expect(pendingMsgs[0].text, 'Failure test');
      expect(pendingMsgs[0].status, MessageStatus.pending);
    });

    test('Incoming Connection Request exposes ConnectionRequestInfo and acceptConnectionRequest is idempotent', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      // Trigger incoming connection request
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'EP_INCOMING_1',
        status: ConnectionStatus.connecting,
        endpointName: 'RemoteDeviceAlpha',
        authenticationToken: '123456',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 20));

      var state = container.read(messagingStateProvider);
      expect(state.connectionStatus, ConnectionStatus.connecting);
      expect(state.activeConnectionRequest, isNotNull);
      expect(state.activeConnectionRequest!.endpointId, 'EP_INCOMING_1');
      expect(state.activeConnectionRequest!.endpointName, 'RemoteDeviceAlpha');
      expect(state.activeConnectionRequest!.authenticationToken, '123456');
      expect(state.activeConnectionRequest!.isIncoming, isTrue);

      // Accept connection
      await notifier.acceptConnectionRequest('EP_INCOMING_1');
      state = container.read(messagingStateProvider);
      expect(state.activeConnectionRequest, isNull); // Cleared immediately for overlay dismissal
      expect(fakeTransport.acceptConnectionCount, 1);
      expect(fakeTransport.acceptedEndpoints, contains('EP_INCOMING_1'));

      // Duplicate accept call should not trigger transport acceptConnection again
      await notifier.acceptConnectionRequest('EP_INCOMING_1');
      expect(fakeTransport.acceptConnectionCount, 1);

      // Reject after accept should be safely ignored
      await notifier.rejectConnectionRequest('EP_INCOMING_1');
      expect(fakeTransport.rejectConnectionCount, 0);
    });

    test('Rejecting connection request calls transport and dismisses overlay', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      // Trigger incoming connection request
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'EP_REJECT_1',
        status: ConnectionStatus.connecting,
        endpointName: 'UntrustedDevice',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 20));

      var state = container.read(messagingStateProvider);
      expect(state.activeConnectionRequest, isNotNull);
      expect(state.activeConnectionRequest!.endpointId, 'EP_REJECT_1');

      // Reject connection
      await notifier.rejectConnectionRequest('EP_REJECT_1');
      state = container.read(messagingStateProvider);
      expect(state.activeConnectionRequest, isNull);
      expect(fakeTransport.rejectConnectionCount, 1);
      expect(fakeTransport.rejectedEndpoints, contains('EP_REJECT_1'));

      // Duplicate reject call should be idempotent
      await notifier.rejectConnectionRequest('EP_REJECT_1');
      expect(fakeTransport.rejectConnectionCount, 1);
    });

    test('Test B - Genuine trusted peer auto-connects and becomes SECURE', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      
      final trustedPeerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      // 1. Create a trusted peer record in the database
      await repo.upsertPeer(
        trustedPeerId,
        'TrustedFriend',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: kCurrentProtocolVersion,
      );

      // 2. Trigger connection request from this trusted peer (resolving the name to TrustedFriend:trustedPeerId)
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_TRUSTED_1',
        status: ConnectionStatus.connecting,
        endpointName: 'TrustedFriend:$trustedPeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // 3. Verify auto-accept was triggered without popping the pairing overlay
      final state = container.read(messagingStateProvider);
      expect(state.activeConnectionRequest, isNull);
      expect(fakeTransport.acceptedEndpoints, contains('EP_TRUSTED_1'));

      // 4. Complete Nearby Connection
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_TRUSTED_1',
        status: ConnectionStatus.connected,
        endpointName: 'TrustedFriend:$trustedPeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // 5. Complete Handshake by sending remote secure identity payload matching the trusted key
      final ephKeyPair = await cryptoService.generateEphemeralKeyPair();
      final ephPub = await ephKeyPair.extractPublicKey();
      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: idKeyPair,
        protocolVersion: kCurrentProtocolVersion,
        peerId: trustedPeerId,
        displayName: 'TrustedFriend',
        identityPublicKeyBytes: idPub.bytes,
        ephemeralPublicKeyBytes: ephPub.bytes,
      );
      final payload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: trustedPeerId,
        displayName: 'TrustedFriend',
        identityPublicKey: Uint8List.fromList(idPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('EP_TRUSTED_1', codec.encodeWireEnvelope(payload));
      await Future.delayed(const Duration(milliseconds: 100));

      // 6. Verify session is now SECURE
      final finalState = container.read(messagingStateProvider);
      expect(finalState.sessions[trustedPeerId], isNotNull);
      expect(finalState.sessions[trustedPeerId]!.isSecure, isTrue);
      expect(finalState.sessions[trustedPeerId]!.status, SessionStatus.connected);
    });

    test('Test A & D - Identity mismatch and spoofing are rejected and raise warning', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      
      final trustedPeerId = const Uuid().v4();
      final genuineKeyPair = await cryptoService.generateIdentityKeyPair();
      final genuinePub = await genuineKeyPair.extractPublicKey();
      final genuinePublicKeyHex = genuinePub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final genuineFingerprint = await cryptoService.computeFingerprint(genuinePub.bytes);

      // 1. Create a trusted peer record with the genuine public key
      await repo.upsertPeer(
        trustedPeerId,
        'TrustedFriend',
        publicKey: genuinePublicKeyHex,
        fingerprint: genuineFingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: kCurrentProtocolVersion,
      );

      // 2. Trigger connection request from spoofed candidate (claiming the trustedPeerId)
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_SPOOFED_1',
        status: ConnectionStatus.connecting,
        endpointName: 'SpoofedName:$trustedPeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify background auto-accept runs (since it only resolves the name suffix hint first)
      expect(fakeTransport.acceptedEndpoints, contains('EP_SPOOFED_1'));

      // 3. Complete connection
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_SPOOFED_1',
        status: ConnectionStatus.connected,
        endpointName: 'SpoofedName:$trustedPeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // 4. Remote sends a handshake payload generated with a DIFFERENT key (spoofed identity)
      final spoofedPayload = await createRemoteHandshake(trustedPeerId, 'SpoofedFriend');
      fakeTransport.triggerIncomingPayload('EP_SPOOFED_1', codec.encodeWireEnvelope(spoofedPayload));
      await Future.delayed(const Duration(milliseconds: 100));

      // 5. Verify mismatch handling: disconnected, no session derived, warning raised
      final state = container.read(messagingStateProvider);
      expect(state.sessions[trustedPeerId]!.isSecure, isFalse);
      expect(state.sessions[trustedPeerId]!.status, SessionStatus.disconnected);
      expect(state.identityMismatchRequest, isNotNull);
      expect(state.identityMismatchRequest!.peerId, trustedPeerId);
      expect(state.identityMismatchRequest!.oldPublicKey, genuinePublicKeyHex);
      expect(state.identityMismatchRequest!.newPublicKey, spoofedPayload.identityPublicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join());

      // 6. User chooses "KEEP BLOCKED"
      await notifier.rejectIdentityChange(trustedPeerId);
      final stateAfterReject = container.read(messagingStateProvider);
      expect(stateAfterReject.identityMismatchRequest, isNull); // Cleared
      
      final dbPeer = await repo.getPeer(trustedPeerId);
      expect(dbPeer!.trustState, PeerTrustState.distrusted); // Blocked
    });

    test('Test F - Distrusted peer is rejected immediately', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      
      final distrustedPeerId = const Uuid().v4();
      await repo.upsertPeer(
        distrustedPeerId,
        'DistrustedPeer',
        publicKey: '01020304',
        fingerprint: '11112222',
        trustState: PeerTrustState.distrusted,
        protocolVersion: kCurrentProtocolVersion,
      );

      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_DISTRUSTED',
        status: ConnectionStatus.connecting,
        endpointName: 'DistrustedPeer:$distrustedPeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Connection rejected immediately
      expect(fakeTransport.rejectedEndpoints, contains('EP_DISTRUSTED'));
      expect(container.read(messagingStateProvider).activeConnectionRequest, isNull);
    });
  });
}
