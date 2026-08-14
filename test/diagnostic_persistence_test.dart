import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/utils/logger.dart';
import 'package:vantra/features/poc/poc_page.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Diagnostic logs survive PocPage disposal and recreation', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fakeTransport = FakeTransport();
    final fakeSecureStorage = FakeSecureStorageService();

    Widget buildApp(Widget home) {
      return ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(fakeTransport),
          secureStorageServiceProvider.overrideWithValue(fakeSecureStorage),
        ],
        child: MaterialApp(
          home: home,
        ),
      );
    }

    // 1. Mount the PocPage
    await tester.pumpWidget(buildApp(const PocPage()));
    await tester.pumpAndSettle();

    // Verify PocPage is loaded
    expect(find.byType(PocPage), findsOneWidget);

    // 2. Generate VANTRA logs using VantraLogger and print inside runZoned to simulate real app environment
    runZoned(() {
      VantraLogger.log('Test log message 1');
      // ignore: avoid_print
      print('[VANTRA] Test print message 2');
    }, zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
        if (line.contains('[VANTRA]')) {
          VantraLogger.printAndLog(line);
        }
      },
    ));

    await tester.pumpAndSettle();

    // Verify logs are displayed on PocPage system console list view
    expect(find.textContaining('Test log message 1'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Test print message 2'), findsAtLeastNWidgets(1));

    // 3. Navigate away / Dispose PocPage by pushing a dummy page
    await tester.pumpWidget(buildApp(const Scaffold(body: Text('Dummy Page'))));
    await tester.pumpAndSettle();

    // Verify PocPage is disposed/not in tree
    expect(find.byType(PocPage), findsNothing);
    expect(find.text('Dummy Page'), findsOneWidget);

    // 4. Generate more VANTRA logs while PocPage is disposed/unmounted
    runZoned(() {
      VantraLogger.log('Test log message 3 while offline');
    }, zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
        if (line.contains('[VANTRA]')) {
          VantraLogger.printAndLog(line);
        }
      },
    ));

    // 5. Re-mount/recreate PocPage
    await tester.pumpWidget(buildApp(const PocPage()));
    await tester.pumpAndSettle();

    // Verify PocPage is back and contains all historical logs (1, 2, and 3)
    expect(find.byType(PocPage), findsOneWidget);
    expect(find.textContaining('Test log message 1'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Test print message 2'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Test log message 3 while offline'), findsAtLeastNWidgets(1));
  });
}
