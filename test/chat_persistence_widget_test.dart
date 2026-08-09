import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/features/messaging/chat_page.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ChatPage loads historical messages from Drift SQLite and displays them', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fakeTransport = FakeTransport();
    final remotePeerId = const Uuid().v4();
    final testDb = AppDatabase.forTesting(NativeDatabase.memory());

    // 1. Pre-populate database with historical conversation messages
    final localPeerId = 'me';
    await prefs.setString('vantra_peer_id', localPeerId);

    final now = DateTime.now().millisecondsSinceEpoch;
    await testDb.messageDao.insertMessage(MessagesCompanion.insert(
      messageId: 'history-1',
      senderId: remotePeerId,
      receiverId: localPeerId,
      messageText: 'Hello from past history',
      timestamp: now - 5000,
      type: 'TEXT',
      status: MessageStatus.received,
      createdAt: now - 5000,
    ));

    await testDb.messageDao.insertMessage(MessagesCompanion.insert(
      messageId: 'history-2',
      senderId: localPeerId,
      receiverId: remotePeerId,
      messageText: 'My past response',
      timestamp: now - 1000,
      type: 'TEXT',
      status: MessageStatus.sent,
      createdAt: now - 1000,
    ));

    // 2. Render ChatPage
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(fakeTransport),
          appDatabaseProvider.overrideWithValue(testDb),
        ],
        child: MaterialApp(
          home: ChatPage(peerId: remotePeerId),
        ),
      ),
    );

    // Let the stream query complete
    await tester.pumpAndSettle();

    // 3. Verify history messages are rendered
    expect(find.text('Hello from past history'), findsOneWidget);
    expect(find.text('My past response'), findsOneWidget);

    // 4. Connect session
    final remotePayload = {
      'type': 'IDENTITY',
      'peerId': remotePeerId,
      'displayName': 'VantraRemotePeer',
    };
    fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Verify Connected banner visible and textfield active
    expect(find.text('Connected'), findsOneWidget);

    // 5. Send new message and verify it appends reactively
    final inputFinder = find.byKey(const Key('chat_input_field'));
    final sendFinder = find.byKey(const Key('chat_send_button'));

    await tester.enterText(inputFinder, 'New real-time message');
    await tester.tap(sendFinder);
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Expect to see new message appended alongside old history
    expect(find.text('New real-time message'), findsOneWidget);
    expect(find.text('Hello from past history'), findsOneWidget); // still there

    // Clean up
    await testDb.close();
  });
}
