import 'package:bulksend/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fileIdOf', () {
    test('같은 입력이면 같은 ID', () {
      expect(fileIdOf('a/b.jpg', 10, 1000), fileIdOf('a/b.jpg', 10, 1000));
    });

    test('경로/크기/수정시각 중 하나라도 다르면 다른 ID', () {
      final base = fileIdOf('a/b.jpg', 10, 1000);
      expect(fileIdOf('a/c.jpg', 10, 1000), isNot(base));
      expect(fileIdOf('a/b.jpg', 11, 1000), isNot(base));
      expect(fileIdOf('a/b.jpg', 10, 1001), isNot(base));
    });

    test('40자리 sha1 hex', () {
      expect(fileIdOf('x', 1, 1), matches(RegExp(r'^[0-9a-f]{40}$')));
    });
  });

  test('TransferFile JSON 왕복', () {
    final f = TransferFile.create(
      relPath: '폴더/사진.heic',
      size: 1234,
      mtime: 1700000000000,
      kind: FileKind.photo,
    );
    final back = TransferFile.fromJson(f.toJson());
    expect(back, f);
    expect(back.id, fileIdOf('폴더/사진.heic', 1234, 1700000000000));
  });

  test('FileStatus JSON 왕복', () {
    const s = FileStatus(id: 'abc', state: FileState.partial, offset: 42);
    expect(FileStatus.fromJson(s.toJson()), s);
  });

  test('SessionRequest JSON 왕복', () {
    const r = SessionRequest(
      pin: '847',
      senderId: 'dev-1',
      senderName: 'Galaxy',
      totalFiles: 3,
      totalBytes: 99,
    );
    expect(SessionRequest.fromJson(r.toJson()), r);
  });
}
