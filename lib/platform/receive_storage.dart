import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/models.dart';
import '../core/storage.dart';

/// 안드로이드 일반 파일 저장 위치
const _androidFolder = '/storage/emulated/0/Download/BulkSend';

/// 안드로이드 갤러리 저장 위치 (MediaStore RELATIVE_PATH)
const _androidGalleryPath = 'DCIM/BulkSend';

/// 사진/동영상은 갤러리(사진 앱)에 저장한다.
/// 갤러리가 거부하는 형식이면 [fallback] 폴더의 `Photos/` 아래에 파일로 남긴다.
class GalleryStorage implements ReceiveStorage {
  GalleryStorage({required this.tempDir, required this.fallback});

  final Directory tempDir;
  final FolderStorage fallback;

  @override
  Future<void> commit(File part, TransferFile meta) async {
    // 갤러리는 확장자로 형식을 판단하므로 원래 파일명으로 바꿔서 넘긴다
    final name = p.basename(safeRelPath(meta.relPath));
    final dir = await Directory(p.join(tempDir.path, meta.id)).create(recursive: true);
    final named = await moveFile(part, p.join(dir.path, name));
    final created = DateTime.fromMillisecondsSinceEpoch(meta.mtime);

    try {
      if (meta.kind == FileKind.video) {
        await PhotoManager.editor.saveVideo(named,
            title: name, relativePath: _androidGalleryPath, creationDate: created);
      } else {
        await PhotoManager.editor.saveImageWithPath(named.path,
            title: name, relativePath: _androidGalleryPath, creationDate: created);
      }
      await dir.delete(recursive: true);
    } catch (_) {
      final meta2 = TransferFile(
          id: meta.id, relPath: 'Photos/$name', size: meta.size, mtime: meta.mtime, kind: FileKind.file);
      await fallback.commit(named, meta2);
      await dir.delete(recursive: true);
    }
  }
}

/// 소스 기준으로 저장 위치를 나눈다: photo/video → 갤러리, file → 폴더
class RoutingStorage implements ReceiveStorage {
  RoutingStorage({required this.gallery, required this.folder});

  final ReceiveStorage gallery;
  final ReceiveStorage folder;

  @override
  Future<void> commit(File part, TransferFile meta) => meta.kind == FileKind.file
      ? folder.commit(part, meta)
      : gallery.commit(part, meta);
}

class ReceiveSetup {
  const ReceiveSetup({required this.storage, required this.workDir, required this.folderPath});

  final ReceiveStorage storage;

  /// 이어받기 상태(.part, done.log) 보관 위치. 앱 내부 저장소.
  final Directory workDir;

  /// 일반 파일이 저장되는 위치 (화면 안내용)
  final String folderPath;
}

/// 받기 전에 권한을 요청하고 플랫폼별 저장소를 만든다.
/// 권한이 없으면 [StateError] 를 던진다.
Future<ReceiveSetup> prepareReceive() async {
  final ps = await PhotoManager.requestPermissionExtend(
    requestOption: const PermissionRequestOption(iosAccessLevel: IosAccessLevel.addOnly),
  );
  if (!ps.hasAccess) throw StateError('사진 저장 권한이 필요해요');

  final Directory folder;
  if (Platform.isAndroid) {
    if (!await Permission.manageExternalStorage.request().isGranted) {
      throw StateError('파일 저장을 위해 "모든 파일 접근" 권한이 필요해요');
    }
    folder = Directory(_androidFolder);
  } else {
    // iOS: Documents 는 파일 앱의 "나의 iPhone > BulkSend" 로 보인다
    folder = await getApplicationDocumentsDirectory();
  }
  await folder.create(recursive: true);

  final support = await getApplicationSupportDirectory();
  final workDir = Directory(p.join(support.path, 'receive'));
  final folderStorage = FolderStorage(folder);
  return ReceiveSetup(
    storage: RoutingStorage(
      gallery: GalleryStorage(
          tempDir: Directory(p.join(support.path, 'gallery_tmp')), fallback: folderStorage),
      folder: folderStorage,
    ),
    workDir: workDir,
    folderPath: folder.path,
  );
}
