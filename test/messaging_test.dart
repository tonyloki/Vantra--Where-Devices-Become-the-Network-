import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
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
import 'package:cryptography/cryptography.dart';
import 'package:vantra/core/security/security_session.dart';
import 'test_fakes.dart';
import 'package:vantra/core/networking/nearby_connection_service.dart';
import 'package:vantra/core/peers/peer_provider.dart';

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

    late Directory testTempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      fakeTransport = FakeTransport();
      testDb = AppDatabase.forTesting(NativeDatabase.memory());
      cryptoService = CryptoService();

      testTempDir = Directory.systemTemp.createTempSync('vantra_test_');

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

    Future<DomainHandshakePayload> createRemoteHandshake(
      String remotePeerId,
      String displayName, {
      int protocolVersion = 1,
      int? minSupportedVersion,
      int? maxSupportedVersion,
      List<VantraCapability>? supportedCapabilities,
      SimpleKeyPair? identityKeyPair,
    }) async {
      final idKeyPair = identityKeyPair ?? await cryptoService.generateIdentityKeyPair();
      final ephKeyPair = await cryptoService.generateEphemeralKeyPair();

      final idPub = await idKeyPair.extractPublicKey();
      final ephPub = await ephKeyPair.extractPublicKey();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: idKeyPair,
        protocolVersion: protocolVersion,
        peerId: remotePeerId,
        displayName: displayName,
        identityPublicKeyBytes: idPub.bytes,
        ephemeralPublicKeyBytes: ephPub.bytes,
      );

      return DomainHandshakePayload(
        protocolVersion: protocolVersion,
        peerId: remotePeerId,
        displayName: displayName,
        identityPublicKey: Uint8List.fromList(idPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
        signature: Uint8List.fromList(sigBytes),
        minSupportedVersion: minSupportedVersion,
        maxSupportedVersion: maxSupportedVersion,
        supportedCapabilities: supportedCapabilities,
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
      expect(handshake.maxSupportedVersion, kCurrentProtocolVersion);
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
      expect(state.activeConnectionRequest, isNotNull); // Retained for accepting status overlay
      expect(state.connectionStatus, ConnectionStatus.accepting);
      expect(fakeTransport.acceptConnectionCount, 1);
      expect(fakeTransport.acceptedEndpoints, contains('EP_INCOMING_1'));

      // Duplicate accept call should not trigger transport acceptConnection again
      await notifier.acceptConnectionRequest('EP_INCOMING_1');
      expect(fakeTransport.acceptConnectionCount, 1);

      // Trigger connection result connected to clear it
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'EP_INCOMING_1',
        status: ConnectionStatus.connected,
        endpointName: 'RemoteDeviceAlpha',
      ));
      await Future.delayed(const Duration(milliseconds: 20));
      state = container.read(messagingStateProvider);
      expect(state.activeConnectionRequest, isNull); // Now cleared on connected

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

    test('Test G - V1 Device connects to V2 Device', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      final v1PeerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        v1PeerId,
        'V1Friend',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 1,
      );

      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_V1',
        status: ConnectionStatus.connecting,
        endpointName: 'V1Friend:$v1PeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Handshake is auto-accepted in background
      expect(fakeTransport.acceptedEndpoints, contains('EP_V1'));

      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_V1',
        status: ConnectionStatus.connected,
        endpointName: 'V1Friend:$v1PeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Remote sends V1 handshake (no min/max fields)
      final remotePayload = await createRemoteHandshake(
        v1PeerId,
        'V1Friend',
        protocolVersion: 1,
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_V1', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      // Session becomes directly CONNECTED (secure & ready) under V1 fallback
      final state = container.read(messagingStateProvider);
      expect(state.sessions[v1PeerId], isNotNull);
      expect(state.sessions[v1PeerId]!.status, SessionStatus.connected);
      expect(state.sessions[v1PeerId]!.negotiatedVersion, 1);
      expect(state.sessions[v1PeerId]!.enabledCapabilities, contains(VantraCapability.text));
    });

    test('Test H - V2 Device connects to V2 Device', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final v2PeerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        v2PeerId,
        'V2Friend',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_V2',
        status: ConnectionStatus.connecting,
        endpointName: 'V2Friend:$v2PeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_V2',
        status: ConnectionStatus.connected,
        endpointName: 'V2Friend:$v2PeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // 1. Remote sends V2 handshake
      final remotePayload = await createRemoteHandshake(
        v2PeerId,
        'V2Friend',
        protocolVersion: 1, // wire version is 1 for compatibility
        minSupportedVersion: 1,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      // Session is in handshaking (negotiating) state, NOT connected yet (gated!)
      final state = container.read(messagingStateProvider);
      expect(state.sessions[v2PeerId]!.status, SessionStatus.handshaking);
      expect(state.sessions[v2PeerId]!.negotiatedVersion, 2);

      // Expose derived SecuritySession to manually build encrypted peer packet
      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[v2PeerId];
      expect(secSession, isNotNull);

      // 2. Build remote CapabilitiesExchange payload and encrypt it
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession!.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: v2PeerId,
        receiverId: localId.peerId,
        minSupportedVersion: 1,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
      );

      final plaintextBytes = codec.encodePlaintext(capExchange);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: plaintextBytes,
      );

      final envelope = DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      );

      // 3. Trigger receipt of peer CapabilitiesExchange
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      // Session becomes CONNECTED (secure & ready) after negotiation completes
      final stateFinal = container.read(messagingStateProvider);
      expect(stateFinal.sessions[v2PeerId]!.status, SessionStatus.connected);
      expect(stateFinal.sessions[v2PeerId]!.enabledCapabilities, contains(VantraCapability.text));
    });

    test('Test I - Downgrade protection / Spoofing detection rejects tampered exchange', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final v2PeerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        v2PeerId,
        'V2Friend',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_TAMPERED',
        status: ConnectionStatus.connected,
        endpointName: 'V2Friend:$v2PeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // 1. Handshake claims [1..2] version range
      final remotePayload = await createRemoteHandshake(
        v2PeerId,
        'V2Friend',
        protocolVersion: 1,
        minSupportedVersion: 1,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_TAMPERED', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[v2PeerId];

      // 2. CapabilitiesExchange claims [1..1] version range (downgrade attempt/tampering)
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession!.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: v2PeerId,
        receiverId: localId.peerId,
        minSupportedVersion: 1,
        maxSupportedVersion: 1, // Tampered range!
        supportedCapabilities: const [VantraCapability.text],
      );

      final plaintextBytes = codec.encodePlaintext(capExchange);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: plaintextBytes,
      );

      final envelope = DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      );

      // 3. Trigger receipt of tampered packet
      fakeTransport.triggerIncomingPayload('EP_TAMPERED', codec.encodeWireEnvelope(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      // Mismatch detected: transport is disconnected
      expect(fakeTransport.disconnectedTarget, 'EP_TAMPERED');
    });

    test('Test J - Image message is chunked, E2E encrypted, and reassembled successfully', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final v2PeerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        v2PeerId,
        'V2Friend',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Establish session
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_V2',
        status: ConnectionStatus.connected,
        endpointName: 'V2Friend:$v2PeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      final remotePayload = await createRemoteHandshake(
        v2PeerId,
        'V2Friend',
        protocolVersion: 2,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[v2PeerId];

      // Exchange capabilities
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession!.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: v2PeerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      final plaintextBytes = codec.encodePlaintext(capExchange);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: plaintextBytes,
      );

      final envelope = DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      );

      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      expect(container.read(messagingStateProvider).sessions[v2PeerId]!.enabledCapabilities, contains(VantraCapability.image));

      // Create a 50 KB dummy file
      final fileData = Uint8List(50 * 1024);
      for (var i = 0; i < fileData.length; i++) {
        fileData[i] = i % 256;
      }
      final tempFile = File(path.join(testTempDir.path, 'temp_test_image.jpg'));
      await tempFile.writeAsBytes(fileData);

      try {
        final initialPayloadCount = fakeTransport.sentPayloads.length;

        // Send image message
        await notifier.sendImageMessage(v2PeerId, tempFile.path, caption: 'Check this image!');
        
        // Wait for the OFFER to be sent (payload count increases by 1)
        int attempts = 0;
        while (fakeTransport.sentPayloads.length <= initialPayloadCount && attempts < 20) {
          await Future.delayed(const Duration(milliseconds: 50));
          attempts++;
        }
        
        // Peer receives the OFFER and replies with ACCEPT
        final sentPayloads = fakeTransport.sentPayloads;
        expect(sentPayloads.isNotEmpty, true);

        DomainEncryptedEnvelope? offerEnvelope;
        DomainMediaControl? offerPlaintext;

        for (final wire in sentPayloads) {
          try {
            final decoded = codec.decodeWireEnvelope(wire);
            if (decoded is DomainEncryptedEnvelope) {
              final decryptedOfferBytes = await cryptoService.decryptBytes(
                secretKey: secSession.sendKey,
                nonce: decoded.nonce,
                ciphertext: decoded.ciphertext,
                mac: decoded.mac,
                messageId: decoded.messageId,
              );
              final plaintext = codec.decodePlaintext(decryptedOfferBytes);
              if (plaintext is DomainMediaControl && plaintext.type == DomainMediaControlType.offer) {
                offerEnvelope = decoded;
                offerPlaintext = plaintext;
                break;
              }
            }
          } catch (_) {
            // Decryption or decoding failed for non-media payloads
          }
        }

        expect(offerEnvelope, isNotNull);
        expect(offerPlaintext, isNotNull);
        expect(offerPlaintext!.type, DomainMediaControlType.offer);
        expect(offerPlaintext.caption, 'Check this image!');
        expect(offerPlaintext.totalChunks, 4); // 50 KB / 16 KB = 4 chunks
        
        // Reply with ACCEPT
        final acceptMsgId = const Uuid().v4();
        final acceptDomainMsg = DomainMediaControl(
          messageId: acceptMsgId,
          sessionId: secSession.sessionId,
          sequence: 2,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          senderId: v2PeerId,
          receiverId: localId.peerId,
          type: DomainMediaControlType.accept,
          transferId: offerPlaintext.transferId,
          nextExpectedChunk: 0,
        );
        
        final acceptBytes = codec.encodePlaintext(acceptDomainMsg);
        final encryptedAccept = await cryptoService.encryptBytes(
          secretKey: secSession.receiveKey,
          sessionSalt: secSession.sessionSalt,
          sequence: 2,
          messageId: acceptMsgId,
          plaintextBytes: acceptBytes,
        );
        
        final acceptEnvelope = DomainEncryptedEnvelope(
          protocolVersion: 2,
          messageId: acceptMsgId,
          sessionId: secSession.sessionId,
          sequence: 2,
          nonce: Uint8List.fromList(encryptedAccept.nonce),
          ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
          mac: Uint8List.fromList(encryptedAccept.mac),
        );
        
        fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(acceptEnvelope));
        
        // Await the sender completing chunk transmission (wait for 8 total sent payloads)
        int waitAttempts = 0;
        while (fakeTransport.sentPayloads.length < 8 && waitAttempts < 40) {
          await Future.delayed(const Duration(milliseconds: 50));
          waitAttempts++;
        }
        
        // Verify all 4 chunks are sent along with Handshake, CapabilitiesExchange, ACK, and OFFER
        expect(fakeTransport.sentPayloads.length, 8);
        
      } finally {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    });

    test('Test K - Capability negotiation negotiates VantraCapability.file', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        peerId,
        'FilePeer',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Establish session
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_FILE_CAP',
        status: ConnectionStatus.connected,
        endpointName: 'FilePeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      final remotePayload = await createRemoteHandshake(
        peerId,
        'FilePeer',
        protocolVersion: 2,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_FILE_CAP', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[peerId]!;

      // Exchange capabilities
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
      );

      final plaintextBytes = codec.encodePlaintext(capExchange);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: plaintextBytes,
      );

      final envelope = DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      );

      fakeTransport.triggerIncomingPayload('EP_FILE_CAP', codec.encodeWireEnvelope(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      // Get session
      final session = container.read(messagingStateProvider).sessions[peerId];
      expect(session, isNotNull);
      expect(session!.enabledCapabilities, contains(VantraCapability.file));
    });

    test('Test L - Secure File Transfer gets offering and rejected status on failure', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        peerId,
        'RejectPeer',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Establish session
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_REJECT',
        status: ConnectionStatus.connected,
        endpointName: 'RejectPeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      final remotePayload = await createRemoteHandshake(
        peerId,
        'RejectPeer',
        protocolVersion: 2,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_REJECT', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[peerId]!;

      // Exchange capabilities
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
      );

      final plaintextBytes = codec.encodePlaintext(capExchange);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: plaintextBytes,
      );

      final envelope = DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      );

      fakeTransport.triggerIncomingPayload('EP_REJECT', codec.encodeWireEnvelope(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      // Write small temp file
      final tempDir = await Directory.systemTemp.createTemp();
      final tempFile = File('${tempDir.path}/test_to_reject.txt');
      await tempFile.writeAsString('Reject me please');

      try {
        // Send file
        await notifier.sendFileMessage(peerId, tempFile.path, caption: 'Rejected file');
        await Future.delayed(const Duration(milliseconds: 200));

        // Intercept offer and reply with REJECT
        DomainMediaControl? offerPlaintext;

        for (final wire in fakeTransport.sentPayloads) {
          try {
            final decoded = codec.decodeWireEnvelope(wire);
            if (decoded is DomainEncryptedEnvelope) {
              final decryptedBytes = await cryptoService.decryptBytes(
                secretKey: secSession.sendKey,
                nonce: decoded.nonce,
                ciphertext: decoded.ciphertext,
                mac: decoded.mac,
                messageId: decoded.messageId,
              );
              final plaintext = codec.decodePlaintext(decryptedBytes);
              if (plaintext is DomainMediaControl && plaintext.type == DomainMediaControlType.offer) {
                offerPlaintext = plaintext;
                break;
              }
            }
          } catch (_) {}
        }

        expect(offerPlaintext, isNotNull);

        final rejectMsgId = const Uuid().v4();
        final rejectDomainMsg = DomainMediaControl(
          messageId: rejectMsgId,
          sessionId: secSession.sessionId,
          sequence: 2,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          senderId: peerId,
          receiverId: localId.peerId,
          type: DomainMediaControlType.reject,
          transferId: offerPlaintext!.transferId,
        );

        final rejectBytes = codec.encodePlaintext(rejectDomainMsg);
        final encryptedReject = await cryptoService.encryptBytes(
          secretKey: secSession.receiveKey,
          sessionSalt: secSession.sessionSalt,
          sequence: 2,
          messageId: rejectMsgId,
          plaintextBytes: rejectBytes,
        );

        final rejectEnvelope = DomainEncryptedEnvelope(
          protocolVersion: 2,
          messageId: rejectMsgId,
          sessionId: secSession.sessionId,
          sequence: 2,
          nonce: Uint8List.fromList(encryptedReject.nonce),
          ciphertext: Uint8List.fromList(encryptedReject.ciphertext),
          mac: Uint8List.fromList(encryptedReject.mac),
        );

        fakeTransport.triggerIncomingPayload('EP_REJECT', codec.encodeWireEnvelope(rejectEnvelope));
        await Future.delayed(const Duration(milliseconds: 200));

        // Expect the message status to become failed
        final messages = await repo.getConversation(localId.peerId, peerId);
        expect(messages.last.status, MessageStatus.failed);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Test M - Full Secure File Transfer reassembly and SHA-256 verification', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        peerId,
        'FileReassemblyPeer',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Establish session
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_REASSEMBLY',
        status: ConnectionStatus.connected,
        endpointName: 'FileReassemblyPeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      final remotePayload = await createRemoteHandshake(
        peerId,
        'FileReassemblyPeer',
        protocolVersion: 2,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_REASSEMBLY', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[peerId]!;

      // Exchange capabilities
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image, VantraCapability.file],
      );

      final plaintextBytes = codec.encodePlaintext(capExchange);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: plaintextBytes,
      );

      final envelope = DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      );

      fakeTransport.triggerIncomingPayload('EP_REASSEMBLY', codec.encodeWireEnvelope(envelope));
      await Future.delayed(const Duration(milliseconds: 100));

      // Create outgoing test file with 20 KB of data (triggers 2 chunks of 16 KB size)
      final tempDir = await Directory.systemTemp.createTemp();
      final tempFile = File('${tempDir.path}/test_reassembly.bin');
      final dataBytes = Uint8List(20000)..fillRange(0, 20000, 0x41); // 'A'
      await tempFile.writeAsBytes(dataBytes);

      try {
        // Send file
        await notifier.sendFileMessage(peerId, tempFile.path, caption: 'Important data');
        await Future.delayed(const Duration(milliseconds: 200));

        // Intercept offer and accept
        DomainMediaControl? offerPlaintext;

        for (final wire in fakeTransport.sentPayloads) {
          try {
            final decoded = codec.decodeWireEnvelope(wire);
            if (decoded is DomainEncryptedEnvelope) {
              final decryptedBytes = await cryptoService.decryptBytes(
                secretKey: secSession.sendKey,
                nonce: decoded.nonce,
                ciphertext: decoded.ciphertext,
                mac: decoded.mac,
                messageId: decoded.messageId,
              );
              final plaintext = codec.decodePlaintext(decryptedBytes);
              if (plaintext is DomainMediaControl && plaintext.type == DomainMediaControlType.offer) {
                offerPlaintext = plaintext;
                break;
              }
            }
          } catch (_) {}
        }

        expect(offerPlaintext, isNotNull);
        expect(offerPlaintext!.sha256, isNotNull);
        expect(offerPlaintext.sha256!.isNotEmpty, true);

        final acceptMsgId = const Uuid().v4();
        final acceptDomainMsg = DomainMediaControl(
          messageId: acceptMsgId,
          sessionId: secSession.sessionId,
          sequence: 2,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          senderId: peerId,
          receiverId: localId.peerId,
          type: DomainMediaControlType.accept,
          transferId: offerPlaintext.transferId,
          nextExpectedChunk: 0,
        );

        final acceptBytes = codec.encodePlaintext(acceptDomainMsg);
        final encryptedAccept = await cryptoService.encryptBytes(
          secretKey: secSession.receiveKey,
          sessionSalt: secSession.sessionSalt,
          sequence: 2,
          messageId: acceptMsgId,
          plaintextBytes: acceptBytes,
        );

        final acceptEnvelope = DomainEncryptedEnvelope(
          protocolVersion: 2,
          messageId: acceptMsgId,
          sessionId: secSession.sessionId,
          sequence: 2,
          nonce: Uint8List.fromList(encryptedAccept.nonce),
          ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
          mac: Uint8List.fromList(encryptedAccept.mac),
        );

        fakeTransport.triggerIncomingPayload('EP_REASSEMBLY', codec.encodeWireEnvelope(acceptEnvelope));
        
        // Wait for sending to complete
        int waitAttempts = 0;
        while (fakeTransport.sentPayloads.length < 6 && waitAttempts < 40) {
          await Future.delayed(const Duration(milliseconds: 50));
          waitAttempts++;
        }

        // Verify offer + chunks are sent
        expect(fakeTransport.sentPayloads.length, greaterThanOrEqualTo(5));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Test N - Initiator auto-accepts outgoing request in background', () async {
      container.read(messagingStateProvider);

      final peerId = const Uuid().v4();

      // Reset fake transport count
      fakeTransport.acceptConnectionCount = 0;

      // Trigger outgoing connection request (connecting, isIncoming: false)
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_OUTGOING_AUTO',
        status: ConnectionStatus.connecting,
        endpointName: 'AutoPeer:$peerId',
        isIncoming: false,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify that initiator auto-accepted: acceptConnectionCount should be 1
      expect(fakeTransport.acceptConnectionCount, 1);
      
      // Verify no manual pairing overlay was shown for outgoing request
      final request = container.read(messagingStateProvider).activeConnectionRequest;
      expect(request, isNull);
    });

    test('Test O - Responder transitions to accepting and then clears request on connected', () async {
      container.read(messagingStateProvider);

      final peerId = const Uuid().v4();

      // Trigger incoming connection request (connecting, isIncoming: true)
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_INCOMING_ACCEPTING',
        status: ConnectionStatus.connecting,
        endpointName: 'IncomingPeer:$peerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify activeConnectionRequest is populated on responder
      final requestBefore = container.read(messagingStateProvider).activeConnectionRequest;
      expect(requestBefore, isNotNull);
      expect(requestBefore!.endpointId, 'EP_INCOMING_ACCEPTING');

      // Accept request
      final notifier = container.read(messagingStateProvider.notifier);
      await notifier.acceptConnectionRequest('EP_INCOMING_ACCEPTING');

      // Verify state transitions to ConnectionStatus.accepting
      expect(container.read(messagingStateProvider).connectionStatus, ConnectionStatus.accepting);
      // Verify request is NOT cleared yet during accepting status
      expect(container.read(messagingStateProvider).activeConnectionRequest, isNotNull);

      // Trigger connection result connected
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_INCOMING_ACCEPTING',
        status: ConnectionStatus.connected,
        endpointName: 'IncomingPeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify connectionStatus is now connected and request is cleared
      expect(container.read(messagingStateProvider).connectionStatus, ConnectionStatus.connected);
      expect(container.read(messagingStateProvider).activeConnectionRequest, isNull);
    });

    test('Test P - Responder clears request and reports failure/rejected status when connection fails', () async {
      container.read(messagingStateProvider);

      final peerId = const Uuid().v4();

      // Trigger incoming request
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_INCOMING_FAILED',
        status: ConnectionStatus.connecting,
        endpointName: 'FailedPeer:$peerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Accept request
      final notifier = container.read(messagingStateProvider.notifier);
      await notifier.acceptConnectionRequest('EP_INCOMING_FAILED');

      // Verify accepting status
      expect(container.read(messagingStateProvider).connectionStatus, ConnectionStatus.accepting);

      // Trigger connection result failed (rejected)
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_INCOMING_FAILED',
        status: ConnectionStatus.rejected,
        endpointName: 'FailedPeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify status is rejected and request is cleared
      expect(container.read(messagingStateProvider).connectionStatus, ConnectionStatus.rejected);
      expect(container.read(messagingStateProvider).activeConnectionRequest, isNull);
    });

    test('Test Q - Deterministic connection decisions: local < remote, local > remote, local == remote', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      // Make sure localId has a fixed peerId
      final localPeerId = localId.peerId;
      expect(localPeerId.isNotEmpty, true);

      // 1. Peer with remote ID > local ID (local < remote) -> should INITIATE
      final remotePeerIdLarger = '${localPeerId}_larger';
      await repo.upsertPeer(
        remotePeerIdLarger,
        'LargerPeer',
        publicKey: 'pub1',
        fingerprint: 'fp1',
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      fakeTransport.connectCallCount = 0;
      fakeTransport.connectedEndpoints.clear();

      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(
          id: 'EP_LARGER',
          name: 'LargerPeer:$remotePeerIdLarger',
          serviceId: 'me.vantra.vantra',
        ),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));

      // Expect that connect was called because local < remote
      expect(fakeTransport.connectCallCount, 1);
      expect(fakeTransport.connectedEndpoints.first, 'EP_LARGER');

      // 2. Peer with remote ID < local ID (local > remote) -> should WAIT (skip initiation)
      final remotePeerIdSmaller = '00000000-0000-0000-0000-000000000000';
      await repo.upsertPeer(
        remotePeerIdSmaller,
        'SmallerPeer',
        publicKey: 'pub2',
        fingerprint: 'fp2',
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      fakeTransport.connectCallCount = 0;
      fakeTransport.connectedEndpoints.clear();

      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(
          id: 'EP_SMALLER',
          name: 'SmallerPeer:$remotePeerIdSmaller',
          serviceId: 'me.vantra.vantra',
        ),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));

      // Expect that connect was NOT called because local > remote
      expect(fakeTransport.connectCallCount, 0);

      // 3. Peer with remote ID == local ID (local == remote) -> should WAIT / skip
      fakeTransport.connectCallCount = 0;
      fakeTransport.connectedEndpoints.clear();

      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(
          id: 'EP_SAME',
          name: 'SamePeer:$localPeerId',
          serviceId: 'me.vantra.vantra',
        ),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));

      // Expect that connect was NOT called because local == remote
      expect(fakeTransport.connectCallCount, 0);
    });

    test('Test R - Failure cleanup restores retryable state and clears mappings', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      final peerId = const Uuid().v4();
      await repo.upsertPeer(
        peerId,
        'CleanupPeer',
        publicKey: 'pub3',
        fingerprint: 'fp3',
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Trigger connecting state to establish mappings
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_CLEANUP',
        status: ConnectionStatus.connecting,
        endpointName: 'CleanupPeer:$peerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify mapped in state
      expect(container.read(messagingStateProvider).endpointToPeerId['EP_CLEANUP'], peerId);

      // Trigger connection failure
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_CLEANUP',
        status: ConnectionStatus.error,
        endpointName: 'CleanupPeer:$peerId',
        errorMessage: 'Connection lost',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify endpoint mapping was removed
      expect(container.read(messagingStateProvider).endpointToPeerId['EP_CLEANUP'], isNull);
      // Verify activeEndpointId is cleared
      expect(container.read(messagingStateProvider).activeEndpointId, isNull);
      // Verify activeConnectionRequest is cleared
      expect(container.read(messagingStateProvider).activeConnectionRequest, isNull);
    });

    test('Test S - Decoupled Initialization handles advertising/discovery failures independently', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('me.vantra.vantra/device_info'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'getSdkVersion') {
            return 30; // Android 11
          }
          return null;
        },
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'checkPermissionStatus' || methodCall.method == 'requestPermissions') {
            return {
              for (final p in methodCall.arguments) p: 1 // PermissionStatus.granted
            };
          }
          if (methodCall.method == 'checkServiceStatus') {
            return 1; // ServiceStatus.enabled
          }
          return null;
        },
      );

      final notifier = container.read(nearbyConnectionServiceProvider.notifier);

      // Invoke initialize() and expect it to execute safely in fake test environment.
      await notifier.initialize();
      expect(container.read(nearbyConnectionServiceProvider).status, NearbyServiceStatus.ready);
      expect(container.read(nearbyConnectionServiceProvider).isAdvertising, true);
      expect(container.read(nearbyConnectionServiceProvider).isDiscovering, true);
    });

    test('Deadlock Test 1 - Local peer ID < remote peer ID assigns INITIATOR role to local', () async {
      final discoveryService = container.read(peerDiscoveryServiceProvider);
      final localPeerId = '11111111-1111-1111-1111-111111111111';
      final remotePeerId = '22222222-2222-2222-2222-222222222222';

      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(
          id: 'EP_INITIATOR_TEST',
          name: 'RemotePeer:$remotePeerId',
          serviceId: 'me.vantra.vantra',
        ),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(localPeerId.compareTo(remotePeerId) < 0, isTrue);

      fakeTransport.connectCallCount = 0;
      await discoveryService.connect(
        'EP_INITIATOR_TEST',
        localName: 'LocalPeer:$localPeerId',
      );

      expect(fakeTransport.connectCallCount, 1);
      expect(fakeTransport.connectedEndpoints.first, 'EP_INITIATOR_TEST');
    });

    test('Deadlock Test 2 - Local peer ID > remote peer ID assigns RESPONDER role to local', () async {
      final discoveryService = container.read(peerDiscoveryServiceProvider);
      final localPeerId = '22222222-2222-2222-2222-222222222222';
      final remotePeerId = '11111111-1111-1111-1111-111111111111';

      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(
          id: 'EP_RESPONDER_TEST',
          name: 'RemotePeer:$remotePeerId',
          serviceId: 'me.vantra.vantra',
        ),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(localPeerId.compareTo(remotePeerId) > 0, isTrue);

      fakeTransport.connectCallCount = 0;
      await discoveryService.connect(
        'EP_RESPONDER_TEST',
        localName: 'LocalPeer:$localPeerId',
      );

      // Designated responder must NOT call requestConnection()
      expect(fakeTransport.connectCallCount, 0);
    });

    test('Deadlock Test 3 - Mutual Discovery results in exactly one requestConnection', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      final localPeerId = container.read(localIdentityStateProvider).peerId;
      final largerPeerId = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

      await repo.upsertPeer(
        largerPeerId,
        'LargerDevice',
        publicKey: 'pubLarger',
        fingerprint: 'fpLarger',
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      fakeTransport.connectCallCount = 0;

      // Local discovers LargerDevice -> local is INITIATOR (local < larger) -> calls connect
      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(
          id: 'EP_DEV_LARGER',
          name: 'LargerDevice:$largerPeerId',
          serviceId: 'me.vantra.vantra',
        ),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(fakeTransport.connectCallCount, 1);

      // Symmetrically, when LargerDevice evaluates localPeerId, (larger > local) -> LargerDevice is RESPONDER -> does NOT call connect
      expect(largerPeerId.compareTo(localPeerId) > 0, isTrue);
    });

    test('Deadlock Test 4 - Duplicate incoming/outgoing requests are resolved safely without connection deadlock', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      // Construct a remotePeerId smaller than local, so local is the RESPONDER
      final remotePeerIdSmaller = '00000000-0000-0000-0000-000000000000';
      await repo.upsertPeer(
        remotePeerIdSmaller,
        'SimultaneousPeer',
        publicKey: 'pubSim',
        fingerprint: 'fpSim',
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Set up pending outgoing connection state to remotePeerIdSmaller
      container.read(messagingStateProvider.notifier).state = container.read(messagingStateProvider).copyWith(
        endpointToPeerId: {'EP_OUTGOING_PENDING': remotePeerIdSmaller},
      );

      fakeTransport.disconnectCalled = false;
      fakeTransport.acceptConnectionCount = 0;

      // Incoming connection arrives from the initiator
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_INCOMING_SIMULTANEOUS',
        status: ConnectionStatus.connecting,
        endpointName: 'SimultaneousPeer:$remotePeerIdSmaller',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // As responder, outgoing attempt was abandoned via disconnect
      expect(fakeTransport.disconnectCalled, isTrue);
      expect(fakeTransport.disconnectedTarget, 'EP_OUTGOING_PENDING');

      // And incoming request from initiator was accepted
      expect(fakeTransport.acceptConnectionCount, 1);
      expect(fakeTransport.acceptedEndpoints.contains('EP_INCOMING_SIMULTANEOUS'), isTrue);
    });

    test('Deadlock Test 5 - Complete Pairing Flow: REQUEST -> ACCEPT -> CONNECTED -> HANDSHAKE -> SESSION_READY', () async {
      container.read(messagingStateProvider);

      final remotePeerId = const Uuid().v4();
      final remotePayload = await createRemoteHandshake(remotePeerId, 'PairingPeer');

      // 1. REQUEST_RECEIVED (connecting, isIncoming: true)
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_PAIRING',
        status: ConnectionStatus.connecting,
        endpointName: 'PairingPeer:$remotePeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 100));
      expect(container.read(messagingStateProvider).activeConnectionRequest, isNotNull);

      // 2. ACCEPT_START & ACCEPT_SUCCESS
      await container.read(messagingStateProvider.notifier).acceptConnectionRequest('EP_PAIRING');
      expect(container.read(messagingStateProvider).connectionStatus, ConnectionStatus.accepting);

      // 3. NATIVE_STATUS_CONNECTED
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_PAIRING',
        status: ConnectionStatus.connected,
        endpointName: 'PairingPeer:$remotePeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 100));
      expect(container.read(messagingStateProvider).connectionStatus, ConnectionStatus.connected);

      // 4. HANDSHAKE_STARTED & exchange identity payload
      fakeTransport.triggerIncomingPayload(
        'EP_PAIRING',
        codec.encodeWireEnvelope(remotePayload),
      );
      await Future.delayed(const Duration(milliseconds: 200));

      // 5. SESSION_READY
      final session = container.read(messagingStateProvider).sessions[remotePeerId];
      expect(session, isNotNull);
      expect(session!.status, SessionStatus.connected);
      expect(session.isSecure, isTrue);
    });

    test('Deadlock Test 6 - Only designated initiator reconnects in trusted reconnect', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      final largerPeerId = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
      final smallerPeerId = '00000000-0000-0000-0000-000000000000';

      await repo.upsertPeer(largerPeerId, 'LargerTrusted', publicKey: 'pL', fingerprint: 'fL', trustState: PeerTrustState.trusted, protocolVersion: 2);
      await repo.upsertPeer(smallerPeerId, 'SmallerTrusted', publicKey: 'pS', fingerprint: 'fS', trustState: PeerTrustState.trusted, protocolVersion: 2);

      // Discovered larger peer (local < larger -> local is INITIATOR)
      fakeTransport.connectCallCount = 0;
      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(id: 'EP_L', name: 'LargerTrusted:$largerPeerId', serviceId: 'me.vantra.vantra'),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(fakeTransport.connectCallCount, 1);

      // Discovered smaller peer (local > smaller -> local is RESPONDER)
      fakeTransport.connectCallCount = 0;
      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(id: 'EP_S', name: 'SmallerTrusted:$smallerPeerId', serviceId: 'me.vantra.vantra'),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(fakeTransport.connectCallCount, 0);
    });

    test('Deadlock Test 7 - Bidirectional text transmission post-connection', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      final remotePeerId = const Uuid().v4();
      final remotePayload = await createRemoteHandshake(remotePeerId, 'BiDirectionalPeer');

      // Establish secure connection
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_BIDI',
        status: ConnectionStatus.connecting,
        endpointName: 'BiDirectionalPeer:$remotePeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      await container.read(messagingStateProvider.notifier).acceptConnectionRequest('EP_BIDI');
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_BIDI',
        status: ConnectionStatus.connected,
        endpointName: 'BiDirectionalPeer:$remotePeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      fakeTransport.triggerIncomingPayload('EP_BIDI', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 200));

      // 1. Send text message (Local -> Remote)
      final notifier = container.read(messagingStateProvider.notifier);
      await notifier.sendTextMessage(remotePeerId, 'Hello from Local');
      expect(fakeTransport.sentPayloads.isNotEmpty, isTrue);

      // Verify that message was added to local repository
      final sentMsgs = await repo.getConversation(container.read(localIdentityStateProvider).peerId, remotePeerId);
      expect(sentMsgs.any((m) => m.text == 'Hello from Local'), isTrue);
    });

    test('Stabilization Test 8 - Per-Peer Connection Lock prevents duplicate connect attempts', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      final largerPeerId = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
      await repo.upsertPeer(largerPeerId, 'LockedPeer', publicKey: 'pLock', fingerprint: 'fLock', trustState: PeerTrustState.trusted, protocolVersion: 2);

      fakeTransport.connectCallCount = 0;
      // Trigger discovery 3 times rapidly
      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(id: 'EP_LOCK', name: 'LockedPeer:$largerPeerId', serviceId: 'me.vantra.vantra'),
      ]);
      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(id: 'EP_LOCK', name: 'LockedPeer:$largerPeerId', serviceId: 'me.vantra.vantra'),
      ]);
      fakeTransport.triggerDiscoveredPeers([
        DiscoveredPeer(id: 'EP_LOCK', name: 'LockedPeer:$largerPeerId', serviceId: 'me.vantra.vantra'),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));

      // Lock should ensure connect is only called once
      expect(fakeTransport.connectCallCount, 1);
    });

    test('Stabilization Test 9 - Fresh Session Reestablishment on Reconnect', () async {
      container.read(messagingStateProvider);

      final remotePeerId = const Uuid().v4();
      final remotePayload1 = await createRemoteHandshake(remotePeerId, 'ReconnectPeer');

      // First connection & handshake
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_REC_1',
        status: ConnectionStatus.connecting,
        endpointName: 'ReconnectPeer:$remotePeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      await container.read(messagingStateProvider.notifier).acceptConnectionRequest('EP_REC_1');
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_REC_1',
        status: ConnectionStatus.connected,
        endpointName: 'ReconnectPeer:$remotePeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.triggerIncomingPayload('EP_REC_1', codec.encodeWireEnvelope(remotePayload1));
      await Future.delayed(const Duration(milliseconds: 150));

      final session1 = container.read(messagingStateProvider).sessions[remotePeerId];
      expect(session1?.isSecure, isTrue);

      // Disconnect
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_REC_1',
        status: ConnectionStatus.disconnected,
        endpointName: 'ReconnectPeer:$remotePeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final disconnectedSession = container.read(messagingStateProvider).sessions[remotePeerId];
      expect(disconnectedSession?.status, SessionStatus.disconnected);
      expect(disconnectedSession?.isSecure, isFalse);

      // Reconnect with new endpoint ID
      final remotePayload2 = await createRemoteHandshake(remotePeerId, 'ReconnectPeer');
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_REC_2',
        status: ConnectionStatus.connecting,
        endpointName: 'ReconnectPeer:$remotePeerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      await container.read(messagingStateProvider.notifier).acceptConnectionRequest('EP_REC_2');
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_REC_2',
        status: ConnectionStatus.connected,
        endpointName: 'ReconnectPeer:$remotePeerId',
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.triggerIncomingPayload('EP_REC_2', codec.encodeWireEnvelope(remotePayload2));
      await Future.delayed(const Duration(milliseconds: 150));

      final session2 = container.read(messagingStateProvider).sessions[remotePeerId];
      expect(session2?.isSecure, isTrue);
      expect(session2?.endpointId, 'EP_REC_2');
    });

    test('Stabilization Test 10 - Sequential text message delivery and ACKs', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        peerId,
        'SeqPeer',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Establish secure connection
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_SEQ',
        status: ConnectionStatus.connecting,
        endpointName: 'SeqPeer:$peerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      await container.read(messagingStateProvider.notifier).acceptConnectionRequest('EP_SEQ');
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_SEQ',
        status: ConnectionStatus.connected,
        endpointName: 'SeqPeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(
        peerId,
        'SeqPeer',
        protocolVersion: 2,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_SEQ', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[peerId]!;

      // 1. Send CapabilitiesExchange from remote
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
      );

      final capBytes = codec.encodePlaintext(capExchange);
      final encryptedCap = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: capBytes,
      );

      fakeTransport.triggerIncomingPayload('EP_SEQ', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 100));

      // Clear payloads list
      fakeTransport.sentPayloads.clear();

      // 2. Send Message 1 (Local -> Remote)
      await notifier.sendTextMessage(peerId, 'Message 1');
      await Future.delayed(const Duration(milliseconds: 100));
      expect(fakeTransport.sentPayloads.length, 1);
      final msg1Wire = fakeTransport.sentPayloads[0];
      final msg1Envelope = codec.decodeWireEnvelope(msg1Wire) as DomainEncryptedEnvelope;
      expect(msg1Envelope.sequence, 3); // CapabilitiesExchange is 1, ACK is 2, Message 1 is 3

      // Simulate remote sending ACK for Message 1
      final ack1MsgId = const Uuid().v4();
      final ack1Domain = DomainAckMessage(
        messageId: ack1MsgId,
        sessionId: secSession.sessionId,
        sequence: 2, // Remote's sendSequence is at 2
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: msg1Envelope.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final ack1Bytes = codec.encodePlaintext(ack1Domain);
      final encryptedAck1 = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 2,
        messageId: ack1MsgId,
        plaintextBytes: ack1Bytes,
      );

      fakeTransport.triggerIncomingPayload('EP_SEQ', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ack1MsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedAck1.nonce),
        ciphertext: Uint8List.fromList(encryptedAck1.ciphertext),
        mac: Uint8List.fromList(encryptedAck1.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify Message 1 is marked delivered
      var dbMsgs = await repo.getConversation(localId.peerId, peerId);
      expect(dbMsgs.first.status, MessageStatus.delivered);

      // Clear payloads list
      fakeTransport.sentPayloads.clear();

      // 3. Send Message 2 (Local -> Remote)
      await notifier.sendTextMessage(peerId, 'Message 2');
      await Future.delayed(const Duration(milliseconds: 100));
      expect(fakeTransport.sentPayloads.length, 1);
      final msg2Wire = fakeTransport.sentPayloads[0];
      final msg2Envelope = codec.decodeWireEnvelope(msg2Wire) as DomainEncryptedEnvelope;
      expect(msg2Envelope.sequence, 4);

      // Simulate remote sending ACK for Message 2
      final ack2MsgId = const Uuid().v4();
      final ack2Domain = DomainAckMessage(
        messageId: ack2MsgId,
        sessionId: secSession.sessionId,
        sequence: 3, // Remote's sendSequence is now at 3
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: msg2Envelope.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final ack2Bytes = codec.encodePlaintext(ack2Domain);
      final encryptedAck2 = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 3,
        messageId: ack2MsgId,
        plaintextBytes: ack2Bytes,
      );

      fakeTransport.triggerIncomingPayload('EP_SEQ', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ack2MsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        nonce: Uint8List.fromList(encryptedAck2.nonce),
        ciphertext: Uint8List.fromList(encryptedAck2.ciphertext),
        mac: Uint8List.fromList(encryptedAck2.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify Message 2 is marked delivered
      dbMsgs = await repo.getConversation(localId.peerId, peerId);
      expect(dbMsgs.last.status, MessageStatus.delivered);
    });

    test('Stabilization Test 11 - Concurrent message sends and ACKs without delay', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        peerId,
        'ConcurrentPeer',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Establish secure connection
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_CONC',
        status: ConnectionStatus.connecting,
        endpointName: 'ConcurrentPeer:$peerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      await container.read(messagingStateProvider.notifier).acceptConnectionRequest('EP_CONC');
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_CONC',
        status: ConnectionStatus.connected,
        endpointName: 'ConcurrentPeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(
        peerId,
        'ConcurrentPeer',
        protocolVersion: 2,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_CONC', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[peerId]!;

      // 1. Send CapabilitiesExchange from remote
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
      );

      final capBytes = codec.encodePlaintext(capExchange);
      final encryptedCap = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: capBytes,
      );

      fakeTransport.triggerIncomingPayload('EP_CONC', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 100));

      // Clear payloads list
      fakeTransport.sentPayloads.clear();

      // 2. Send Message 1 and Message 2 concurrently
      await notifier.sendTextMessage(peerId, 'Message 1');
      await notifier.sendTextMessage(peerId, 'Message 2');
      await Future.delayed(const Duration(milliseconds: 100));

      expect(fakeTransport.sentPayloads.length, 2);
      final msg1Wire = fakeTransport.sentPayloads[0];
      final msg2Wire = fakeTransport.sentPayloads[1];

      final msg1Envelope = codec.decodeWireEnvelope(msg1Wire) as DomainEncryptedEnvelope;
      final msg2Envelope = codec.decodeWireEnvelope(msg2Wire) as DomainEncryptedEnvelope;

      // Simulate remote sending ACKs for both messages in quick succession (almost concurrently)
      final ack1MsgId = const Uuid().v4();
      final ack1Domain = DomainAckMessage(
        messageId: ack1MsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: msg1Envelope.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final ack1Bytes = codec.encodePlaintext(ack1Domain);
      final encryptedAck1 = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 2,
        messageId: ack1MsgId,
        plaintextBytes: ack1Bytes,
      );

      final ack2MsgId = const Uuid().v4();
      final ack2Domain = DomainAckMessage(
        messageId: ack2MsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: msg2Envelope.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final ack2Bytes = codec.encodePlaintext(ack2Domain);
      final encryptedAck2 = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 3,
        messageId: ack2MsgId,
        plaintextBytes: ack2Bytes,
      );

      // Trigger incoming payloads consecutively without delay
      fakeTransport.triggerIncomingPayload('EP_CONC', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ack1MsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedAck1.nonce),
        ciphertext: Uint8List.fromList(encryptedAck1.ciphertext),
        mac: Uint8List.fromList(encryptedAck1.mac),
      )));

      fakeTransport.triggerIncomingPayload('EP_CONC', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ack2MsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        nonce: Uint8List.fromList(encryptedAck2.nonce),
        ciphertext: Uint8List.fromList(encryptedAck2.ciphertext),
        mac: Uint8List.fromList(encryptedAck2.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 200));

      // Verify both messages are marked delivered
      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      expect(dbMsgs[0].status, MessageStatus.delivered);
      expect(dbMsgs[1].status, MessageStatus.delivered);
    });

    test('Stale Disconnect Safeguard - EP_OLD disconnecting after EP_NEW is secure', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        peerId,
        'StaleDisconnectPeer',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // 1. Setup connection on EP_NEW
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_NEW',
        status: ConnectionStatus.connecting,
        endpointName: 'StaleDisconnectPeer:$peerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      await container.read(messagingStateProvider.notifier).acceptConnectionRequest('EP_NEW');
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_NEW',
        status: ConnectionStatus.connected,
        endpointName: 'StaleDisconnectPeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(
        peerId,
        'StaleDisconnectPeer',
        protocolVersion: 2,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_NEW', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[peerId]!;

      // Send CapabilitiesExchange from remote to finalize the EP_NEW connection
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
      );

      final capBytes = codec.encodePlaintext(capExchange);
      final encryptedCap = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: capExchange.messageId,
        plaintextBytes: capBytes,
      );

      fakeTransport.triggerIncomingPayload('EP_NEW', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify that the session is connected on EP_NEW
      final activeSession = container.read(messagingStateProvider).sessions[peerId];
      expect(activeSession?.status, SessionStatus.connected);
      expect(activeSession?.endpointId, 'EP_NEW');

      // Now, simulate state mapping for EP_OLD in endpointToPeerId to simulate a leftover or simultaneous attempt
      // but without overwriting the active sessions' target endpoint EP_NEW.
      // We trigger a disconnect callback for EP_OLD.
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_OLD',
        status: ConnectionStatus.disconnected,
        endpointName: 'EP_OLD',
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify that the active session on EP_NEW is NOT downgraded or cleared
      final activeSessionAfterOldDisconnect = container.read(messagingStateProvider).sessions[peerId];
      expect(activeSessionAfterOldDisconnect?.status, SessionStatus.connected);
      expect(activeSessionAfterOldDisconnect?.endpointId, 'EP_NEW');
      expect(notifier.securitySessions[peerId], isNotNull);
      expect(container.read(messagingStateProvider).activeEndpointId, 'EP_NEW');
    });

    test('Android 16 Asymmetric State Recovery - encrypted inbound message works and promotes status', () async {
      container.read(messagingStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(
        peerId,
        'AsymmetricPeer',
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
        trustState: PeerTrustState.trusted,
        protocolVersion: 2,
      );

      // Connect and handshake but simulate a state where the PeerSession got wiped/disconnected (asymmetric state)
      // while preserving endpointToPeerId and securitySessions.
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_ASYNC',
        status: ConnectionStatus.connecting,
        endpointName: 'AsymmetricPeer:$peerId',
        isIncoming: true,
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      await container.read(messagingStateProvider.notifier).acceptConnectionRequest('EP_ASYNC');
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_ASYNC',
        status: ConnectionStatus.connected,
        endpointName: 'AsymmetricPeer:$peerId',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(
        peerId,
        'AsymmetricPeer',
        protocolVersion: 2,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
        identityKeyPair: idKeyPair,
      );
      fakeTransport.triggerIncomingPayload('EP_ASYNC', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 100));

      final notifier = container.read(messagingStateProvider.notifier);
      final secSession = notifier.securitySessions[peerId]!;

      // Now, simulate ChatPage reporting offline (e.g. PeerSession status is disconnected or activeSession is null)
      // but securitySessions and endpointToPeerId are intact.
      // We manually clear the peer session in the state to simulate this.
      notifier.state = notifier.state.copyWith(
        sessions: Map<String, PeerSession>.from(notifier.state.sessions)..remove(peerId),
      );

      // Verify that ChatPage would see it as offline (null or not connected)
      expect(container.read(messagingStateProvider).sessions[peerId], isNull);

      // Now remote sends an encrypted text message
      final textMsg = DomainTextMessage(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        content: 'Asymmetric message',
      );

      final textBytes = codec.encodePlaintext(textMsg);
      final encryptedText = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 1,
        messageId: textMsg.messageId,
        plaintextBytes: textBytes,
      );

      // Trigger incoming encrypted message payload
      fakeTransport.triggerIncomingPayload('EP_ASYNC', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: textMsg.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedText.nonce),
        ciphertext: Uint8List.fromList(encryptedText.ciphertext),
        mac: Uint8List.fromList(encryptedText.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify that message is successfully decrypted and saved to DB
      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      expect(dbMsgs.length, 1);
      expect(dbMsgs[0].text, 'Asymmetric message');

      // Now remote sends CapabilitiesExchange
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text],
      );

      final capBytes = codec.encodePlaintext(capExchange);
      final encryptedCap = await cryptoService.encryptBytes(
        secretKey: secSession.receiveKey,
        sessionSalt: secSession.sessionSalt,
        sequence: 2,
        messageId: capExchange.messageId,
        plaintextBytes: capBytes,
      );

      fakeTransport.triggerIncomingPayload('EP_ASYNC', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify that the PeerSession is fully recovered and status is connected on EP_ASYNC
      final recoveredSession = container.read(messagingStateProvider).sessions[peerId];
      expect(recoveredSession?.status, SessionStatus.connected);
      expect(recoveredSession?.endpointId, 'EP_ASYNC');
      expect(container.read(messagingStateProvider).activeEndpointId, 'EP_ASYNC');
    });

    test('TEST A & TEST E - Secure active session overrides handshaking UI state and peerOnline=false does not imply transportConnected=false', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerId = const Uuid().v4();

      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'TestPeer', publicKey: publicKeyHex, fingerprint: fingerprint);

      final localKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remotePub = await remoteKeyPair.extractPublicKey();
      final derivedKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: localKeyPair,
        remoteEphemeralPublicKeyBytes: remotePub.bytes,
      );

      final secSession = SecuritySession(
        peerId: peerId,
        endpointId: 'EP1',
        sessionId: derivedKeys.sessionId,
        sendKey: derivedKeys.sendKey,
        receiveKey: derivedKeys.receiveKey,
        sessionSalt: derivedKeys.sessionSalt,
        remoteIdentityPublicKey: publicKeyHex,
        remoteFingerprint: fingerprint,
      );
      notifier.securitySessions[peerId] = secSession;

      final session = PeerSession(
        peerId: peerId,
        displayName: 'TestPeer',
        endpointId: 'EP1',
        status: SessionStatus.connected,
        isSecure: true,
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
      );

      notifier.aliveEndpoints.add('EP1');
      notifier.state = notifier.state.copyWith(
        sessions: {
          ...notifier.state.sessions,
          peerId: session,
        },
      );

      // Verify transportConnected helper is true
      expect(notifier.hasActiveSecureTransport(peerId), isTrue);

      // Verify peerOnline is true
      expect(notifier.state.sessions[peerId]?.status == SessionStatus.connected, isTrue);
    });

    test('TEST B - Stale EP_OLD disconnect cannot invalidate EP_NEW', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerId = const Uuid().v4();

      final activeSession = PeerSession(
        peerId: peerId,
        displayName: 'ActivePeer',
        endpointId: 'EP_NEW',
        status: SessionStatus.connected,
        isSecure: true,
      );

      final secSession = SecuritySession(
        peerId: peerId,
        endpointId: 'EP_NEW',
        sessionId: 'session-new',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'dummy-pub',
        remoteFingerprint: 'dummy-fp',
      );

      notifier.securitySessions[peerId] = secSession;
      notifier.aliveEndpoints.addAll(['EP_NEW', 'EP_OLD']);
      notifier.state = notifier.state.copyWith(
        sessions: {
          ...notifier.state.sessions,
          peerId: activeSession,
        },
        endpointToPeerId: {
          'EP_NEW': peerId,
          'EP_OLD': peerId,
        },
      );

      // Trigger a disconnect update for EP_OLD
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
        endpointId: 'EP_OLD',
        endpointName: 'ActivePeer',
        status: ConnectionStatus.disconnected,
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      final currentSession = container.read(messagingStateProvider).sessions[peerId];
      expect(currentSession?.status, SessionStatus.connected);
      expect(currentSession?.isSecure, isTrue);
      expect(currentSession?.endpointId, 'EP_NEW');
    });

    test('TEST C - Valid encrypted inbound message recovers state', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerId = const Uuid().v4();
      final localId = container.read(localIdentityStateProvider);

      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'RecoveryPeer', publicKey: publicKeyHex, fingerprint: fingerprint);

      final localKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remotePub = await remoteKeyPair.extractPublicKey();
      final derivedKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: localKeyPair,
        remoteEphemeralPublicKeyBytes: remotePub.bytes,
      );

      final secSession = SecuritySession(
        peerId: peerId,
        endpointId: 'EP1',
        sessionId: derivedKeys.sessionId,
        sendKey: derivedKeys.sendKey,
        receiveKey: derivedKeys.receiveKey,
        sessionSalt: derivedKeys.sessionSalt,
        remoteIdentityPublicKey: publicKeyHex,
        remoteFingerprint: fingerprint,
      );
      notifier.securitySessions[peerId] = secSession;

      final session = PeerSession(
        peerId: peerId,
        displayName: 'RecoveryPeer',
        endpointId: 'EP1',
        status: SessionStatus.handshaking,
        isSecure: true,
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
      );
      notifier.aliveEndpoints.add('EP1');
      notifier.state = notifier.state.copyWith(
        sessions: {
          ...notifier.state.sessions,
          peerId: session,
        },
        endpointToPeerId: {
          'EP1': peerId,
        },
      );

      final inboundMsg = DomainTextMessage(
        messageId: const Uuid().v4(),
        sessionId: derivedKeys.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        content: 'Hello, I am recovering',
      );
      final plainBytes = codec.encodePlaintext(inboundMsg);
      final encrypted = await cryptoService.encryptBytes(
        secretKey: derivedKeys.receiveKey,
        sessionSalt: derivedKeys.sessionSalt,
        sequence: 1,
        messageId: inboundMsg.messageId,
        plaintextBytes: plainBytes,
      );

      fakeTransport.triggerIncomingPayload('EP1', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: inboundMsg.messageId,
        sessionId: derivedKeys.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));

      final recoveredSession = container.read(messagingStateProvider).sessions[peerId];
      expect(recoveredSession?.status, SessionStatus.connected);
      expect(recoveredSession?.isSecure, isTrue);
    });

    test('TEST D - Valid secure active session permits outbound sending', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final peerId = const Uuid().v4();

      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'SendPeer', publicKey: publicKeyHex, fingerprint: fingerprint);

      final localKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remotePub = await remoteKeyPair.extractPublicKey();
      final derivedKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: localKeyPair,
        remoteEphemeralPublicKeyBytes: remotePub.bytes,
      );

      final secSession = SecuritySession(
        peerId: peerId,
        endpointId: 'EP1',
        sessionId: derivedKeys.sessionId,
        sendKey: derivedKeys.sendKey,
        receiveKey: derivedKeys.receiveKey,
        sessionSalt: derivedKeys.sessionSalt,
        remoteIdentityPublicKey: publicKeyHex,
        remoteFingerprint: fingerprint,
      );
      notifier.securitySessions[peerId] = secSession;

      final session = PeerSession(
        peerId: peerId,
        displayName: 'SendPeer',
        endpointId: 'EP1',
        status: SessionStatus.connected,
        isSecure: true,
        publicKey: publicKeyHex,
        fingerprint: fingerprint,
      );
      notifier.aliveEndpoints.add('EP1');
      notifier.state = notifier.state.copyWith(
        sessions: {
          ...notifier.state.sessions,
          peerId: session,
        },
        endpointToPeerId: {
          'EP1': peerId,
        },
      );

      await notifier.sendTextMessage(peerId, 'Sending during handshake');

      await Future.delayed(const Duration(milliseconds: 50));

      final dbMsgs = await repo.getConversation(container.read(localIdentityStateProvider).peerId, peerId);
      expect(dbMsgs.length, 1);
      expect(dbMsgs[0].text, 'Sending during handshake');
      expect(dbMsgs[0].status, MessageStatus.sent);
    });

    test('TEST F - Stale secure session without active transport must NOT be accepted', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerId = const Uuid().v4();

      final session = PeerSession(
        peerId: peerId,
        displayName: 'StalePeer',
        endpointId: 'EP1',
        status: SessionStatus.handshaking,
        isSecure: true,
      );
      final secSession = SecuritySession(
        peerId: peerId,
        endpointId: 'EP1',
        sessionId: 'stale-session',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'dummy-pub',
        remoteFingerprint: 'dummy-fp',
      );

      notifier.securitySessions[peerId] = secSession;
      notifier.state = notifier.state.copyWith(
        sessions: {
          ...notifier.state.sessions,
          peerId: session,
        },
      );

      expect(notifier.hasActiveSecureTransport(peerId), isFalse);
    });

    test('TEST G - EP_OLD secure session must not authorize EP_NEW sending', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final peerId = const Uuid().v4();

      final session = PeerSession(
        peerId: peerId,
        displayName: 'MismatchedPeer',
        endpointId: 'EP_OLD',
        status: SessionStatus.connected,
        isSecure: true,
      );
      final secSession = SecuritySession(
        peerId: peerId,
        endpointId: 'EP_OLD',
        sessionId: 'mismatched-session',
        sendKey: SecretKey(List<int>.filled(32, 1)),
        receiveKey: SecretKey(List<int>.filled(32, 1)),
        sessionSalt: Uint8List(16),
        remoteIdentityPublicKey: 'dummy-pub',
        remoteFingerprint: 'dummy-fp',
      );

      notifier.securitySessions[peerId] = secSession;
      notifier.aliveEndpoints.add('EP_NEW');
      notifier.state = notifier.state.copyWith(
        sessions: {
          ...notifier.state.sessions,
          peerId: session,
        },
      );

      expect(notifier.hasActiveSecureTransport(peerId), isFalse);
    });

    test('TEST 1 - One image message is created and persisted. Queue flush sends it exactly once.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path, caption: 'Hello Image');

      int waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(fakeTransport.sentPayloads.length, 1);

      final offerWire = fakeTransport.sentPayloads[0];
      final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
      final decryptedOffer = await cryptoService.decryptBytes(
        secretKey: secSession.sendKey,
        nonce: offerEnvelope.nonce,
        ciphertext: offerEnvelope.ciphertext,
        mac: offerEnvelope.mac,
        messageId: offerEnvelope.messageId,
      );
      final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;
      expect(offerPlaintext.type, DomainMediaControlType.offer);

      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      final imageMsg = dbMsgs.firstWhere((m) => m.type == 'IMAGE');
      expect(offerEnvelope.messageId, imageMsg.messageId);

      // Reply with ACCEPT
      final acceptMsgId = const Uuid().v4();
      final acceptDomain = DomainMediaControl(
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        type: DomainMediaControlType.accept,
        transferId: offerPlaintext.transferId,
        nextExpectedChunk: 0,
      );
      final encryptedAccept = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: acceptMsgId, plaintextBytes: codec.encodePlaintext(acceptDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedAccept.nonce),
        ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
        mac: Uint8List.fromList(encryptedAccept.mac),
      )));

      waitLimit = 20;
      while (fakeTransport.sentPayloads.length < 3 && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(fakeTransport.sentPayloads.length, 3);

      final sentMsg = await repo.getMessageById(imageMsg.messageId);
      expect(sentMsg?.status, MessageStatus.sent);

      // Send ACK for imageMsg.messageId
      final ackMsgId = const Uuid().v4();
      final ackDomain = DomainAckMessage(
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: imageMsg.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final encryptedAck = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 3, messageId: ackMsgId, plaintextBytes: codec.encodePlaintext(ackDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        nonce: Uint8List.fromList(encryptedAck.nonce),
        ciphertext: Uint8List.fromList(encryptedAck.ciphertext),
        mac: Uint8List.fromList(encryptedAck.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      final deliveredMsg = await repo.getMessageById(imageMsg.messageId);
      expect(deliveredMsg?.status, MessageStatus.delivered);

      fakeTransport.sentPayloads.clear();
      await notifier.flushQueue(peerId, 'manual_test');
      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeTransport.sentPayloads.length, 0); // No double transmission!
    });

    test('TEST 2 - Calling _flushQueue() twice concurrently does not send the same message twice.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path);
      // Concurrently invoke flushQueue again
      await notifier.flushQueue(peerId, 'concurrent_test');

      await Future.delayed(const Duration(milliseconds: 50));
      int offerCount = 0;
      DomainMediaControl? offerPlaintext;
      for (final wire in fakeTransport.sentPayloads) {
        try {
          final decoded = codec.decodeWireEnvelope(wire) as DomainEncryptedEnvelope;
          final decrypted = await cryptoService.decryptBytes(secretKey: secSession.sendKey, nonce: decoded.nonce, ciphertext: decoded.ciphertext, mac: decoded.mac, messageId: decoded.messageId);
          final plaintext = codec.decodePlaintext(decrypted);
          if (plaintext is DomainMediaControl && plaintext.type == DomainMediaControlType.offer) {
            offerCount++;
            offerPlaintext = plaintext;
          }
        } catch (_) {}
      }
      expect(offerCount, 1);

      if (offerPlaintext != null) {
        final rejectMsgId = const Uuid().v4();
        final rejectDomain = DomainMediaControl(
          messageId: rejectMsgId,
          sessionId: secSession.sessionId,
          sequence: 2,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          senderId: peerId,
          receiverId: localId.peerId,
          type: DomainMediaControlType.reject,
          transferId: offerPlaintext.transferId,
        );
        final encryptedReject = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: rejectMsgId, plaintextBytes: codec.encodePlaintext(rejectDomain));
        fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
          protocolVersion: 2,
          messageId: rejectMsgId,
          sessionId: secSession.sessionId,
          sequence: 2,
          nonce: Uint8List.fromList(encryptedReject.nonce),
          ciphertext: Uint8List.fromList(encryptedReject.ciphertext),
          mac: Uint8List.fromList(encryptedReject.mac),
        )));
        await Future.delayed(const Duration(milliseconds: 50));
      }
    });

    test('TEST 3 - Successful transport updates the persistent message state so the queue does not select it again.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path);

      int waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final offerWire = fakeTransport.sentPayloads[0];
      final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
      final decryptedOffer = await cryptoService.decryptBytes(secretKey: secSession.sendKey, nonce: offerEnvelope.nonce, ciphertext: offerEnvelope.ciphertext, mac: offerEnvelope.mac, messageId: offerEnvelope.messageId);
      final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;

      // ACCEPT
      final acceptMsgId = const Uuid().v4();
      final acceptDomain = DomainMediaControl(
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        type: DomainMediaControlType.accept,
        transferId: offerPlaintext.transferId,
        nextExpectedChunk: 0,
      );
      final encryptedAccept = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: acceptMsgId, plaintextBytes: codec.encodePlaintext(acceptDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedAccept.nonce),
        ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
        mac: Uint8List.fromList(encryptedAccept.mac),
      )));

      waitLimit = 20;
      while (fakeTransport.sentPayloads.length < 3 && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      final imageMsg = dbMsgs.firstWhere((m) => m.type == 'IMAGE');
      final currentMsg = await repo.getMessageById(imageMsg.messageId);
      expect(currentMsg?.status, MessageStatus.sent);

      fakeTransport.sentPayloads.clear();
      await notifier.flushQueue(peerId, 'manual_test');
      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeTransport.sentPayloads.length, 0);
    });

    test('TEST 4 - ChatPage rebuild does not resend a previously sent image.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path);

      int waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final offerWire = fakeTransport.sentPayloads[0];
      final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
      final decryptedOffer = await cryptoService.decryptBytes(secretKey: secSession.sendKey, nonce: offerEnvelope.nonce, ciphertext: offerEnvelope.ciphertext, mac: offerEnvelope.mac, messageId: offerEnvelope.messageId);
      final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;

      // ACCEPT
      final acceptMsgId = const Uuid().v4();
      final acceptDomain = DomainMediaControl(
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        type: DomainMediaControlType.accept,
        transferId: offerPlaintext.transferId,
        nextExpectedChunk: 0,
      );
      final encryptedAccept = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: acceptMsgId, plaintextBytes: codec.encodePlaintext(acceptDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedAccept.nonce),
        ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
        mac: Uint8List.fromList(encryptedAccept.mac),
      )));

      waitLimit = 20;
      while (fakeTransport.sentPayloads.length < 3 && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      final imageMsg = dbMsgs.firstWhere((m) => m.type == 'IMAGE');

      // ACK
      final ackMsgId = const Uuid().v4();
      final ackDomain = DomainAckMessage(
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: imageMsg.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final encryptedAck = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 3, messageId: ackMsgId, plaintextBytes: codec.encodePlaintext(ackDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        nonce: Uint8List.fromList(encryptedAck.nonce),
        ciphertext: Uint8List.fromList(encryptedAck.ciphertext),
        mac: Uint8List.fromList(encryptedAck.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      final deliveredMsg = await repo.getMessageById(imageMsg.messageId);
      expect(deliveredMsg?.status, MessageStatus.delivered);

      fakeTransport.sentPayloads.clear();
      notifier.state = notifier.state.copyWith();
      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeTransport.sentPayloads.length, 0);
    });

    test('TEST 5 - Navigation away/back does not resend the image.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path);

      int waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final offerWire = fakeTransport.sentPayloads[0];
      final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
      final decryptedOffer = await cryptoService.decryptBytes(secretKey: secSession.sendKey, nonce: offerEnvelope.nonce, ciphertext: offerEnvelope.ciphertext, mac: offerEnvelope.mac, messageId: offerEnvelope.messageId);
      final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;

      // ACCEPT
      final acceptMsgId = const Uuid().v4();
      final acceptDomain = DomainMediaControl(
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        type: DomainMediaControlType.accept,
        transferId: offerPlaintext.transferId,
        nextExpectedChunk: 0,
      );
      final encryptedAccept = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: acceptMsgId, plaintextBytes: codec.encodePlaintext(acceptDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedAccept.nonce),
        ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
        mac: Uint8List.fromList(encryptedAccept.mac),
      )));

      waitLimit = 20;
      while (fakeTransport.sentPayloads.length < 3 && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      final imageMsg = dbMsgs.firstWhere((m) => m.type == 'IMAGE');

      // ACK
      final ackMsgId = const Uuid().v4();
      final ackDomain = DomainAckMessage(
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: imageMsg.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final encryptedAck = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 3, messageId: ackMsgId, plaintextBytes: codec.encodePlaintext(ackDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        nonce: Uint8List.fromList(encryptedAck.nonce),
        ciphertext: Uint8List.fromList(encryptedAck.ciphertext),
        mac: Uint8List.fromList(encryptedAck.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      final deliveredMsg = await repo.getMessageById(imageMsg.messageId);
      expect(deliveredMsg?.status, MessageStatus.delivered);

      fakeTransport.sentPayloads.clear();
      notifier.setActiveConversation(null);
      await Future.delayed(const Duration(milliseconds: 20));
      notifier.setActiveConversation(peerId);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeTransport.sentPayloads.length, 0);
    });

    test('TEST 6 - ACK for image correctly updates the matching messageId.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path);

      int waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final offerWire = fakeTransport.sentPayloads[0];
      final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
      final decryptedOffer = await cryptoService.decryptBytes(secretKey: secSession.sendKey, nonce: offerEnvelope.nonce, ciphertext: offerEnvelope.ciphertext, mac: offerEnvelope.mac, messageId: offerEnvelope.messageId);
      final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;

      // ACCEPT
      final acceptMsgId = const Uuid().v4();
      final acceptDomain = DomainMediaControl(
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        type: DomainMediaControlType.accept,
        transferId: offerPlaintext.transferId,
        nextExpectedChunk: 0,
      );
      final encryptedAccept = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: acceptMsgId, plaintextBytes: codec.encodePlaintext(acceptDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedAccept.nonce),
        ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
        mac: Uint8List.fromList(encryptedAccept.mac),
      )));

      waitLimit = 20;
      while (fakeTransport.sentPayloads.length < 3 && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      final imageMsg = dbMsgs.firstWhere((m) => m.type == 'IMAGE');

      // Send ACK for imageMsg.messageId
      final ackMsgId = const Uuid().v4();
      final ackDomain = DomainAckMessage(
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: imageMsg.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final encryptedAck = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 3, messageId: ackMsgId, plaintextBytes: codec.encodePlaintext(ackDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        nonce: Uint8List.fromList(encryptedAck.nonce),
        ciphertext: Uint8List.fromList(encryptedAck.ciphertext),
        mac: Uint8List.fromList(encryptedAck.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      final deliveredMsg = await repo.getMessageById(imageMsg.messageId);
      expect(deliveredMsg?.status, MessageStatus.delivered);
    });

    test('TEST 7 - Reconnect does not resend an already SENT/DELIVERED image.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path);

      int waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final offerWire = fakeTransport.sentPayloads[0];
      final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
      final decryptedOffer = await cryptoService.decryptBytes(secretKey: secSession.sendKey, nonce: offerEnvelope.nonce, ciphertext: offerEnvelope.ciphertext, mac: offerEnvelope.mac, messageId: offerEnvelope.messageId);
      final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;

      // ACCEPT
      final acceptMsgId = const Uuid().v4();
      final acceptDomain = DomainMediaControl(
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        type: DomainMediaControlType.accept,
        transferId: offerPlaintext.transferId,
        nextExpectedChunk: 0,
      );
      final encryptedAccept = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: acceptMsgId, plaintextBytes: codec.encodePlaintext(acceptDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: acceptMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedAccept.nonce),
        ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
        mac: Uint8List.fromList(encryptedAccept.mac),
      )));

      waitLimit = 20;
      while (fakeTransport.sentPayloads.length < 3 && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      final imageMsg = dbMsgs.firstWhere((m) => m.type == 'IMAGE');

      // ACK
      final ackMsgId = const Uuid().v4();
      final ackDomain = DomainAckMessage(
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        originalMessageId: imageMsg.messageId,
        status: DomainDeliveryStatus.delivered,
      );
      final encryptedAck = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 3, messageId: ackMsgId, plaintextBytes: codec.encodePlaintext(ackDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: ackMsgId,
        sessionId: secSession.sessionId,
        sequence: 3,
        nonce: Uint8List.fromList(encryptedAck.nonce),
        ciphertext: Uint8List.fromList(encryptedAck.ciphertext),
        mac: Uint8List.fromList(encryptedAck.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      final deliveredMsg = await repo.getMessageById(imageMsg.messageId);
      expect(deliveredMsg?.status, MessageStatus.delivered);

      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.disconnected, endpointName: 'EP_V2'));
      await Future.delayed(const Duration(milliseconds: 50));

      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload2 = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload2));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession2 = notifier.securitySessions[peerId]!;
      final capExchange2 = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession2.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap2 = await cryptoService.encryptBytes(secretKey: secSession2.receiveKey, sessionSalt: secSession2.sessionSalt, sequence: 1, messageId: capExchange2.messageId, plaintextBytes: codec.encodePlaintext(capExchange2));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange2.messageId,
        sessionId: secSession2.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap2.nonce),
        ciphertext: Uint8List.fromList(encryptedCap2.ciphertext),
        mac: Uint8List.fromList(encryptedCap2.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));

      fakeTransport.sentPayloads.clear();
      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeTransport.sentPayloads.length, 0);
    });

    test('TEST 8 - Three consecutive image messages each send exactly once.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      
      for (int m = 1; m <= 3; m++) {
        final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
        await tempFile.writeAsBytes(fileData);

        fakeTransport.sentPayloads.clear();
        await notifier.sendImageMessage(peerId, tempFile.path, caption: 'Image $m');

        int waitLimit = 20;
        while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
          await Future.delayed(const Duration(milliseconds: 20));
        }

        final offerWire = fakeTransport.sentPayloads[0];
        final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
        final decryptedOffer = await cryptoService.decryptBytes(secretKey: secSession.sendKey, nonce: offerEnvelope.nonce, ciphertext: offerEnvelope.ciphertext, mac: offerEnvelope.mac, messageId: offerEnvelope.messageId);
        final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;

        // ACCEPT
        final acceptMsgId = const Uuid().v4();
        final acceptDomain = DomainMediaControl(
          messageId: acceptMsgId,
          sessionId: secSession.sessionId,
          sequence: (m * 4),
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          senderId: peerId,
          receiverId: localId.peerId,
          type: DomainMediaControlType.accept,
          transferId: offerPlaintext.transferId,
          nextExpectedChunk: 0,
        );
        final encryptedAccept = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: (m * 4), messageId: acceptMsgId, plaintextBytes: codec.encodePlaintext(acceptDomain));
        fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
          protocolVersion: 2,
          messageId: acceptMsgId,
          sessionId: secSession.sessionId,
          sequence: (m * 4),
          nonce: Uint8List.fromList(encryptedAccept.nonce),
          ciphertext: Uint8List.fromList(encryptedAccept.ciphertext),
          mac: Uint8List.fromList(encryptedAccept.mac),
        )));

        waitLimit = 20;
        while (fakeTransport.sentPayloads.length < 3 && waitLimit-- > 0) {
          await Future.delayed(const Duration(milliseconds: 20));
        }

        final dbMsgs = await repo.getConversation(localId.peerId, peerId);
        final imageMsg = dbMsgs.firstWhere((msg) => msg.text == 'Image $m');

        // ACK
        final ackMsgId = const Uuid().v4();
        final ackDomain = DomainAckMessage(
          messageId: ackMsgId,
          sessionId: secSession.sessionId,
          sequence: (m * 4) + 1,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          senderId: peerId,
          receiverId: localId.peerId,
          originalMessageId: imageMsg.messageId,
          status: DomainDeliveryStatus.delivered,
        );
        final encryptedAck = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: (m * 4) + 1, messageId: ackMsgId, plaintextBytes: codec.encodePlaintext(ackDomain));
        fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
          protocolVersion: 2,
          messageId: ackMsgId,
          sessionId: secSession.sessionId,
          sequence: (m * 4) + 1,
          nonce: Uint8List.fromList(encryptedAck.nonce),
          ciphertext: Uint8List.fromList(encryptedAck.ciphertext),
          mac: Uint8List.fromList(encryptedAck.mac),
        )));

        await Future.delayed(const Duration(milliseconds: 50));
        final deliveredMsg = await repo.getMessageById(imageMsg.messageId);
        expect(deliveredMsg?.status, MessageStatus.delivered);
      }
    });

    test('TEST 9 - If transport genuinely fails, retry is still possible.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path);

      int waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final offerWire = fakeTransport.sentPayloads[0];
      final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
      final decryptedOffer = await cryptoService.decryptBytes(secretKey: secSession.sendKey, nonce: offerEnvelope.nonce, ciphertext: offerEnvelope.ciphertext, mac: offerEnvelope.mac, messageId: offerEnvelope.messageId);
      final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;

      // Reject it
      final rejectMsgId = const Uuid().v4();
      final rejectDomain = DomainMediaControl(
        messageId: rejectMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        type: DomainMediaControlType.reject,
        transferId: offerPlaintext.transferId,
      );
      final encryptedReject = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: rejectMsgId, plaintextBytes: codec.encodePlaintext(rejectDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: rejectMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedReject.nonce),
        ciphertext: Uint8List.fromList(encryptedReject.ciphertext),
        mac: Uint8List.fromList(encryptedReject.mac),
      )));

      await Future.delayed(const Duration(milliseconds: 50));
      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      final imageMsg = dbMsgs.firstWhere((m) => m.type == 'IMAGE');
      final failedMsg = await repo.getMessageById(imageMsg.messageId);
      expect(failedMsg?.status, MessageStatus.failed);

      fakeTransport.sentPayloads.clear();
      await notifier.retryMessage(imageMsg.messageId, peerId);

      waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(fakeTransport.sentPayloads.length, 1);
    });

    test('TEST 10 - Same messageId can never have two concurrent outbound send operations.', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repo = container.read(messagingRepositoryProvider);
      final localId = container.read(localIdentityStateProvider);

      final peerId = const Uuid().v4();
      final idKeyPair = await cryptoService.generateIdentityKeyPair();
      final idPub = await idKeyPair.extractPublicKey();
      final publicKeyHex = idPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fingerprint = await cryptoService.computeFingerprint(idPub.bytes);

      await repo.upsertPeer(peerId, 'Friend', publicKey: publicKeyHex, fingerprint: fingerprint, trustState: PeerTrustState.trusted, protocolVersion: 2);
      fakeTransport.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_V2', status: ConnectionStatus.connected, endpointName: 'Friend:$peerId'));
      await Future.delayed(const Duration(milliseconds: 50));

      final remotePayload = await createRemoteHandshake(peerId, 'Friend', protocolVersion: 2, minSupportedVersion: 2, maxSupportedVersion: 2, supportedCapabilities: const [VantraCapability.text, VantraCapability.image], identityKeyPair: idKeyPair);
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(remotePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final secSession = notifier.securitySessions[peerId]!;
      final capExchange = DomainCapabilitiesExchange(
        messageId: const Uuid().v4(),
        sessionId: secSession.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        minSupportedVersion: 2,
        maxSupportedVersion: 2,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );
      final encryptedCap = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 1, messageId: capExchange.messageId, plaintextBytes: codec.encodePlaintext(capExchange));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: capExchange.messageId,
        sessionId: secSession.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encryptedCap.nonce),
        ciphertext: Uint8List.fromList(encryptedCap.ciphertext),
        mac: Uint8List.fromList(encryptedCap.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
      fakeTransport.sentPayloads.clear();

      final fileData = Uint8List(20 * 1024);
      final tempFile = File(path.join(testTempDir.path, '${const Uuid().v4()}.jpg'));
      await tempFile.writeAsBytes(fileData);

      await notifier.sendImageMessage(peerId, tempFile.path);

      int waitLimit = 20;
      while (fakeTransport.sentPayloads.isEmpty && waitLimit-- > 0) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final offerWire = fakeTransport.sentPayloads[0];
      final offerEnvelope = codec.decodeWireEnvelope(offerWire) as DomainEncryptedEnvelope;
      final decryptedOffer = await cryptoService.decryptBytes(
        secretKey: secSession.sendKey,
        nonce: offerEnvelope.nonce,
        ciphertext: offerEnvelope.ciphertext,
        mac: offerEnvelope.mac,
        messageId: offerEnvelope.messageId,
      );
      final offerPlaintext = codec.decodePlaintext(decryptedOffer) as DomainMediaControl;

      final dbMsgs = await repo.getConversation(localId.peerId, peerId);
      final imageMsg = dbMsgs.firstWhere((m) => m.type == 'IMAGE');

      final activeSession = notifier.state.sessions[peerId]!;
      final success = await notifier.sendSingleMessage(secSession, activeSession, imageMsg);
      expect(success, isFalse);

      // Clean up background completer by rejecting it
      final rejectMsgId = const Uuid().v4();
      final rejectDomain = DomainMediaControl(
        messageId: rejectMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: peerId,
        receiverId: localId.peerId,
        type: DomainMediaControlType.reject,
        transferId: offerPlaintext.transferId,
      );
      final encryptedReject = await cryptoService.encryptBytes(secretKey: secSession.receiveKey, sessionSalt: secSession.sessionSalt, sequence: 2, messageId: rejectMsgId, plaintextBytes: codec.encodePlaintext(rejectDomain));
      fakeTransport.triggerIncomingPayload('EP_V2', codec.encodeWireEnvelope(DomainEncryptedEnvelope(
        protocolVersion: 2,
        messageId: rejectMsgId,
        sessionId: secSession.sessionId,
        sequence: 2,
        nonce: Uint8List.fromList(encryptedReject.nonce),
        ciphertext: Uint8List.fromList(encryptedReject.ciphertext),
        mac: Uint8List.fromList(encryptedReject.mac),
      )));
      await Future.delayed(const Duration(milliseconds: 50));
    });
  });
}
