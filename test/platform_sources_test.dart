import 'package:bulksend/platform/send_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skipBytes: 청크 경계를 넘어 앞부분을 버린다', () async {
    final src = Stream.fromIterable([
      [0, 1, 2],
      [3, 4],
      [5, 6, 7],
    ]);
    expect(await skipBytes(src, 4).expand((c) => c).toList(), [4, 5, 6, 7]);
  });

  test('skipBytes: 0 이면 그대로', () async {
    final src = Stream.fromIterable([
      [1, 2],
    ]);
    expect(await skipBytes(src, 0).expand((c) => c).toList(), [1, 2]);
  });
}
