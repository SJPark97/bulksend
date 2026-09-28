import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// 다 받은 임시파일(.part)을 최종 위치로 옮기는 역할.
/// 플랫폼별 구현(갤러리/파일 폴더)은 이 인터페이스를 따른다.
abstract interface class ReceiveStorage {
  /// [part] 는 호출 후 삭제되거나 이동된 상태여야 한다.
  Future<void> commit(File part, TransferFile meta);
}

/// 보낸 쪽이 준 상대경로에서 상위 경로 탈출('..')과 빈 조각을 제거한다.
String safeRelPath(String relPath) {
  final parts = relPath
      .split(RegExp(r'[/\\]'))
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  return parts.isEmpty ? 'unnamed' : parts.join('/');
}

/// 같은 이름이 있으면 `이름 (1).ext` 형태로 비어 있는 경로를 찾는다.
Future<File> uniqueFile(String path) async {
  var candidate = File(path);
  final dir = p.dirname(path);
  final base = p.basenameWithoutExtension(path);
  final ext = p.extension(path);
  for (var i = 1; await candidate.exists(); i++) {
    candidate = File(p.join(dir, '$base ($i)$ext'));
  }
  return candidate;
}

/// rename 은 파일시스템이 다르면 실패하므로(앱 내부 → 공용 저장소) 복사로 대체한다.
Future<File> moveFile(File src, String destPath) async {
  try {
    return await src.rename(destPath);
  } on FileSystemException {
    final copied = await src.copy(destPath);
    await src.delete();
    return copied;
  }
}

/// 상대경로 그대로 [root] 아래에 저장한다. (안드 Download/BulkSend, iOS Documents)
class FolderStorage implements ReceiveStorage {
  FolderStorage(this.root);

  final Directory root;

  @override
  Future<void> commit(File part, TransferFile meta) => save(part, meta);

  /// [commit] 과 같고, 저장된 파일을 돌려준다.
  Future<File> save(File part, TransferFile meta) async {
    final target = await uniqueFile(p.join(root.path, safeRelPath(meta.relPath)));
    await target.parent.create(recursive: true);
    final saved = await moveFile(part, target.path);
    try {
      await saved.setLastModified(DateTime.fromMillisecondsSinceEpoch(meta.mtime));
    } on FileSystemException {
      // 수정시각 복원은 가능한 경우에만
    }
    return saved;
  }
}
