import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/models.dart';
import '../core/storage.dart';

/// 안드로이드 일반 파일 저장 위치
const _androidFolder = '/storage/emulated/0/Download/BulkSend';

/// 안드로이드 갤러리 저장 위치
const _androidGalleryFolder = '/storage/emulated/0/DCIM/BulkSend';

const _mediaChannel = MethodChannel('bulksend/media');

/// iOS: 사진/동영상은 사진 앱에 저장한다 (촬영일은 creationDate 로 지정).
/// 사진 앱이 거부하는 형식이면 [fallback] 폴더의 `Photos/` 아래에 파일로 남긴다.
class GalleryStorage implements ReceiveStorage {
  GalleryStorage({required this.tempDir, required this.fallback});

  final Directory tempDir;
  final FolderStorage fallback;

  @override
  Future<void> commit(File part, TransferFile meta) async {
    // 사진 앱은 확장자로 형식을 판단하므로 원래 파일명으로 바꿔서 넘긴다
    final name = p.basename(safeRelPath(meta.relPath));
    final dir = await Directory(p.join(tempDir.path, meta.id)).create(recursive: true);
    final named = await moveFile(part, p.join(dir.path, name));
    final created = DateTime.fromMillisecondsSinceEpoch(meta.mtime);

    try {
      if (meta.kind == FileKind.video) {
        await PhotoManager.editor.saveVideo(named, title: name, creationDate: created);
      } else {
        await PhotoManager.editor.saveImageWithPath(named.path, title: name, creationDate: created);
      }
    } catch (_) {
      final meta2 = TransferFile(
          id: meta.id, relPath: 'Photos/$name', size: meta.size, mtime: meta.mtime, kind: FileKind.file);
      await fallback.commit(named, meta2);
    }
    await dir.delete(recursive: true);
  }
}

/// 안드로이드: 갤러리 폴더(DCIM/BulkSend)에 직접 저장하고, 수정시각을 원래 날짜로 맞춘 뒤 미디어 스캔한다.
///
/// MediaStore 로 넣으면 새 파일의 수정시각이 "지금"이라, 스캐너가 시간대 정보 없는 EXIF 촬영일을
/// 버려(수정시각과 24시간 넘게 차이 나면 버림) 갤러리에 "오늘 찍은 사진"으로 보인다.
/// 앱이 DATE_TAKEN 을 직접 고치는 것도 Android 11+ 에서는 무시된다.
class AndroidGalleryStorage implements ReceiveStorage {
  final _folder = FolderStorage(Directory(_androidGalleryFolder));

  @override
  Future<void> commit(File part, TransferFile meta) async {
    // 갤러리는 폴더 구조 없이 파일명만 쓴다
    final flat = TransferFile(
        id: meta.id,
        relPath: p.basename(safeRelPath(meta.relPath)),
        size: meta.size,
        mtime: meta.mtime,
        kind: meta.kind);
    final saved = await _folder.save(part, flat);
    try {
      await _mediaChannel.invokeMethod<String>('scanFile', {'path': saved.path});
    } on PlatformException {
      // 스캔을 못 해도 파일은 저장돼 있고, 시스템이 나중에 스캔한다
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
  final support = await getApplicationSupportDirectory();
  final workDir = Directory(p.join(support.path, 'receive'));

  if (Platform.isAndroid) {
    // 갤러리·다운로드 폴더 모두 파일로 직접 쓰므로 "모든 파일 접근" 권한만 있으면 된다
    if (!await Permission.manageExternalStorage.request().isGranted) {
      throw StateError('파일 저장을 위해 "모든 파일 접근" 권한이 필요해요');
    }
    final folder = await Directory(_androidFolder).create(recursive: true);
    return ReceiveSetup(
      storage: RoutingStorage(gallery: AndroidGalleryStorage(), folder: FolderStorage(folder)),
      workDir: workDir,
      folderPath: folder.path,
    );
  }

  // iOS 는 "추가만 허용"이면 저장 직후 새 에셋을 다시 읽지 못해 photo_manager 가 실패를 돌려준다.
  // (저장은 이미 된 상태라 대체 폴더에 한 번 더 저장되는 중복이 생김) → 읽기/쓰기 권한으로 요청.
  // 사용자가 "제한된 접근"을 골라도 앱이 만든 에셋은 읽을 수 있어 괜찮다.
  final ps = await PhotoManager.requestPermissionExtend();
  if (!ps.hasAccess) throw StateError('사진 저장 권한이 필요해요');

  // Documents 는 파일 앱의 "나의 iPhone > BulkSend" 로 보인다
  final folderStorage = FolderStorage(await getApplicationDocumentsDirectory());
  return ReceiveSetup(
    storage: RoutingStorage(
      gallery: GalleryStorage(
          tempDir: Directory(p.join(support.path, 'gallery_tmp')), fallback: folderStorage),
      folder: folderStorage,
    ),
    workDir: workDir,
    folderPath: '파일 앱 > 나의 iPhone > BulkSend',
  );
}
