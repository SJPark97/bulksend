import 'package:bulksend/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('홈에 보내기/받기 버튼', (tester) async {
    await tester.pumpWidget(const BulkSendApp());
    expect(find.text('보내기'), findsOneWidget);
    expect(find.text('받기'), findsOneWidget);
  });
}
