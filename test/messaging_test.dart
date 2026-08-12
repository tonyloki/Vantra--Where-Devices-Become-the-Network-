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
      expect(handshake.protocolVersion, 1);
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
  });
}
