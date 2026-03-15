import 'package:flutter_test/flutter_test.dart';
import 'package:chat_mate/main.dart';

void main() {
  testWidgets('Splash screen renders correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const WatchTogetherApp());

    // Splash screen should show app name
    expect(find.text('Watch Together'), findsOneWidget);
  });

  testWidgets('Home screen has Share and Watch buttons', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const WatchTogetherApp());

    // Skip splash delay by pumping all pending timers
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Watch'), findsOneWidget);
  });
}
