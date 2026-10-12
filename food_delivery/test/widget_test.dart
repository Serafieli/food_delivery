import 'package:flutter_test/flutter_test.dart';
import 'package:food_delivery/main.dart';

void main() {
  testWidgets('Tokyo app loads main screen', (tester) async {
    await tester.pumpWidget(const TokyoApp());
    expect(find.text('Tokyo Суши'), findsOneWidget);
  });
}
