import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/features/messaging/chat_page.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ChatPage renders messages, handles text composition, and disables input on disconnect', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fakeTransport = FakeTransport();
    final remotePeerId = const Uuid().v4();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(fakeTransport),
        ],
        child: MaterialApp(
          home: ChatPage(peerId: remotePeerId),
        ),
      ),
    );

    // Initial state: disconnected, input fields disabled
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);

    final inputFinder = find.byKey(const Key('chat_input_field'));
    final sendFinder = find.byKey(const Key('chat_send_button'));

    expect(tester.widget<TextField>(inputFinder).enabled, isFalse);
    expect(tester.widget<IconButton>(sendFinder).onPressed, isNull);

    // Establish connection by triggering identity handshake
    final remotePayload = {
      'type': 'IDENTITY',
      'peerId': remotePeerId,
      'displayName': 'RemoteFriend',
    };
    fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
    await tester.pumpAndSettle();

    // Verify status changes to Connected
    expect(find.text('Connected'), findsOneWidget);
    expect(tester.widget<TextField>(inputFinder).enabled, isTrue);

    // Type a message and send it
    await tester.enterText(inputFinder, 'Hello from Local Device');
    await tester.tap(sendFinder);
    await tester.pumpAndSettle();

    // Verify it is displayed in the list
    expect(find.text('Hello from Local Device'), findsOneWidget);

    // Trigger an incoming text payload from remote
    final incomingPayload = {
      'type': 'TEXT',
      'messageId': const Uuid().v4(),
      'senderId': remotePeerId,
      'receiverId': 'me',
      'text': 'Reply from Remote Device',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(incomingPayload))));
    await tester.pumpAndSettle();

    // Verify remote message is displayed
    expect(find.text('Reply from Remote Device'), findsOneWidget);

    // Trigger disconnection
    fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
      endpointId: 'QHZD',
      status: ConnectionStatus.disconnected,
      endpointName: 'QHZD',
    ));
    await tester.pumpAndSettle();

    // Verify status and input disabled
    expect(find.text('Disconnected'), findsOneWidget);
    expect(tester.widget<TextField>(inputFinder).enabled, isFalse);
    expect(tester.widget<IconButton>(sendFinder).onPressed, isNull);
  });
}
