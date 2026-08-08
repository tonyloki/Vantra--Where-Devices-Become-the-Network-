import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vantra/main.dart';

void main() {
  testWidgets('VantraApp splash screen loads smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      const ProviderScope(
        child: VantraApp(),
      ),
    );

    // Verify that the splash screen shows VANTRA
    expect(find.text('VANTRA'), findsOneWidget);
    expect(find.text('Where Devices Become the Network.'), findsOneWidget);

    // Let the splash timer complete so that there are no pending timers
    await tester.pump(const Duration(seconds: 2));
  });
}
