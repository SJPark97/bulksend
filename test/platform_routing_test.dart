import 'dart:io';

import 'package:bulksend/core/models.dart';
import 'package:bulksend/core/storage.dart';
import 'package:bulksend/platform/receive_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder implements ReceiveStorage {
  final kinds = <FileKind>[];
  @override
  Future<void> commit(File part, TransferFile meta) async => kinds.add(meta.kind);
}

void main() {
  test('photo/video 는 갤러리, file 은 폴더로', () async {
    final gallery = _Recorder();
    final folder = _Recorder();
    final storage = RoutingStorage(gallery: gallery, folder: folder);
    for (final k in FileKind.values) {
      await storage.commit(
          File('x'), TransferFile.create(relPath: 'a', size: 1, mtime: 1, kind: k));
    }
    expect(gallery.kinds, [FileKind.photo, FileKind.video]);
    expect(folder.kinds, [FileKind.file]);
  });
}
