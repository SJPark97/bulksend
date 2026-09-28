import 'dart:io';

import 'package:bulksend/core/models.dart';
import 'package:bulksend/core/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late FolderStorage storage;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bulksend_storage');
    storage = FolderStorage(Directory(p.join(tmp.path, 'out')));
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<File> part(String content) async {
    final f = File(p.join(tmp.path, 'x.part'));
    await f.writeAsString(content);
    return f;
  }

  TransferFile meta(String relPath) => TransferFile.create(
      relPath: relPath, size: 1, mtime: 1600000000000, kind: FileKind.file);

  test('safeRelPath: 상위 경로 탈출과 빈 조각 제거', () {
    expect(safeRelPath('../../etc/passwd'), 'etc/passwd');
    expect(safeRelPath('/a//./b/../c.txt'), 'a/b/c.txt');
    expect(safeRelPath('..'), 'unnamed');
  });

  test('같은 이름이 있으면 (1), (2) 붙여 저장', () async {
    await storage.commit(await part('1'), meta('a/photo.jpg'));
    await storage.commit(await part('2'), meta('a/photo.jpg'));
    await storage.commit(await part('3'), meta('a/photo.jpg'));

    final dir = p.join(tmp.path, 'out', 'a');
    expect(await File(p.join(dir, 'photo.jpg')).readAsString(), '1');
    expect(await File(p.join(dir, 'photo (1).jpg')).readAsString(), '2');
    expect(await File(p.join(dir, 'photo (2).jpg')).readAsString(), '3');
  });

  test('임시파일은 이동되고 수정시각 복원', () async {
    final f = await part('x');
    await storage.commit(f, meta('b.txt'));
    expect(await f.exists(), false);
    final saved = File(p.join(tmp.path, 'out', 'b.txt'));
    expect((await saved.lastModified()).millisecondsSinceEpoch, 1600000000000);
  });
}
