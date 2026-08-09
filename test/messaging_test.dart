import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/errors/vantra_exceptions.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VantraMessage Serialization Tests', () {
    test('Successful serialization & deserialization', () {
      final msg = VantraMessage(
        messageId: const Uuid().v4(),
        senderId: 'sender-123',
        receiverId: 'receiver-456',
        text: 'Hello Vantra POC',
        timestamp: 1690000000000,
      );

      final jsonMap = msg.toJson();
      expect(jsonMap['type'], 'TEXT');
      expect(jsonMap['messageId'], msg.messageId);
      expect(jsonMap['senderId'], 'sender-123');
      expect(jsonMap['receiverId'], 'receiver-456');
      expect(jsonMap['text'], 'Hello Vantra POC');
      expect(jsonMap['timestamp'], 1690000000000);

      final decoded = VantraMessage.fromJson(jsonMap);
      expect(decoded.messageId, msg.messageId);
      expect(decoded.senderId, msg.senderId);
      expect(decoded.receiverId, msg.receiverId);
      expect(decoded.text, msg.text);
      expect(decoded.timestamp, msg.timestamp);
    });

    test('Malformed and missing field JSON handling should throw TypeError or FormatException', () {
      final badJson = {'type': 'TEXT', 'messageId': '123'}; // missing other fields
      expect(() => VantraMessage.fromJson(badJson), throwsA(isA<TypeError>()));
    });
  });

  group('MessagingNotifier & Identity Handshake Tests', () {
    late FakeTransport fakeTransport;
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      fakeTransport = FakeTransport();
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(fakeTransport),
        ],
      );
    });

    tearDown(() {
      container.dispose();
    });

    test('Loads persistent peerId and displayName from SharedPreferences', () async {
      final localIdentity = container.read(localIdentityStateProvider);
      expect(localIdentity.peerId, isNotEmpty);
      expect(localIdentity.displayName, startsWith('Vantra-'));

      // Save a custom name
      await container.read(localIdentityStateProvider.notifier).updateDisplayName('VantraCustom');
      final updatedIdentity = container.read(localIdentityStateProvider);
      expect(updatedIdentity.displayName, 'VantraCustom');
      expect(updatedIdentity.peerId, localIdentity.peerId); // same persistent UUID
    });

    test('Identity handshake triggers immediately upon connection', () async {
      final localIdentity = container.read(localIdentityStateProvider);
      // Initialize notifier to listen
      container.read(messagingStateProvider);

      // Trigger connected update from Transport
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'RemoteDevice',
      ));

      // Wait a tick for StreamSubscription callback to process
      await Future.delayed(Duration.zero);

      // Check if identity handshake payload was sent
      expect(fakeTransport.sentTargets.length, 1);
      expect(fakeTransport.sentTargets[0], 'QHZD');

      final sentPayload = jsonDecode(utf8.decode(fakeTransport.sentPayloads[0])) as Map<String, dynamic>;
      expect(sentPayload['type'], 'IDENTITY');
      expect(sentPayload['peerId'], localIdentity.peerId);
      expect(sentPayload['displayName'], localIdentity.displayName);
    });

    test('Identity payload establishes peer session and supports reconnection mapping', () async {
      // Initialize notifier to listen
      container.read(messagingStateProvider);

      // Trigger remote device identity handshake payload
      final remotePeerId = const Uuid().v4();
      final remotePayload = {
        'type': 'IDENTITY',
        'peerId': remotePeerId,
        'displayName': 'VantraRemote',
      };
      
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(Duration.zero);

      final state = container.read(messagingStateProvider);
      expect(state.sessions[remotePeerId], isNotNull);
      expect(state.sessions[remotePeerId]!.displayName, 'VantraRemote');
      expect(state.sessions[remotePeerId]!.endpointId, 'QHZD');
      expect(state.sessions[remotePeerId]!.status, SessionStatus.connected);
      expect(state.endpointToPeerId['QHZD'], remotePeerId);

      // Reconnect test: Peer reconnects with a new endpointId 'XVAA'
      final remotePayloadReconnect = {
        'type': 'IDENTITY',
        'peerId': remotePeerId,
        'displayName': 'VantraRemoteUpdated',
      };
      fakeTransport.triggerIncomingPayload('XVAA', Uint8List.fromList(utf8.encode(jsonEncode(remotePayloadReconnect))));
      await Future.delayed(Duration.zero);

      final stateAfterReconnect = container.read(messagingStateProvider);
      expect(stateAfterReconnect.sessions[remotePeerId]!.endpointId, 'XVAA');
      expect(stateAfterReconnect.sessions[remotePeerId]!.displayName, 'VantraRemoteUpdated');
      expect(stateAfterReconnect.sessions[remotePeerId]!.status, SessionStatus.connected);
      expect(stateAfterReconnect.endpointToPeerId['XVAA'], remotePeerId);
    });

    test('Disconnections update the mapped peer session status', () async {
      container.read(messagingStateProvider);

      final remotePeerId = const Uuid().v4();
      final remotePayload = {
        'type': 'IDENTITY',
        'peerId': remotePeerId,
        'displayName': 'VantraRemote',
      };
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(Duration.zero);

      // Verify connected
      expect(container.read(messagingStateProvider).sessions[remotePeerId]!.status, SessionStatus.connected);

      // Trigger disconnected update
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.disconnected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(Duration.zero);

      // Verify disconnected status
      expect(container.read(messagingStateProvider).sessions[remotePeerId]!.status, SessionStatus.disconnected);
    });

    test('Sending text message adds to history and throws error if disconnected', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider); // ensure initialized

      // Trigger connected update from Transport to simulate handshake first
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(Duration.zero);

      final remotePeerId = const Uuid().v4();
      final remotePayload = {
        'type': 'IDENTITY',
        'peerId': remotePeerId,
        'displayName': 'VantraRemote',
      };
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(Duration.zero);

      // Send text message successfully
      await notifier.sendTextMessage(remotePeerId, 'Test Message payload');
      
      final state = container.read(messagingStateProvider);
      expect(state.messageHistory[remotePeerId]!.length, 1);
      expect(state.messageHistory[remotePeerId]![0].text, 'Test Message payload');

      // Verify transport payload
      expect(fakeTransport.sentTargets.length, 2); // 1 identity handshake, 1 text message
      expect(fakeTransport.sentTargets[1], 'QHZD');
      
      final sentTextPayload = jsonDecode(utf8.decode(fakeTransport.sentPayloads[1])) as Map<String, dynamic>;
      expect(sentTextPayload['type'], 'TEXT');
      expect(sentTextPayload['text'], 'Test Message payload');

      // Disconnect and try to send again — should fail
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.disconnected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(Duration.zero);

      expect(() => notifier.sendTextMessage(remotePeerId, 'Failure test'), throwsA(isA<VantraException>()));
    });
  });
}
