import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/models.dart';
import '../core/sender.dart';

/// 파일시스템의 파일 하나
class FileSendItem implements SendItem {
  FileSendItem(this.file, this.meta);

  final File file;

  @override
  final TransferFile meta;

  static Future<FileSendItem> of(File file, String relPath) async {
    final stat = await file.stat();
    return FileSendItem(
      file,
      TransferFile.create(
        relPath: relPath,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
        kind: FileKind.file,
      ),
    );
  }

  @override
  Future<OpenedItem> open(int offset) async =>
      OpenedItem(file.openRead(offset), await file.length());

  @override
  Future<void> release() async {}
}

/// 사진 라이브러리 항목. 원본은 전송 직전에 꺼내고(iOS 는 임시파일로 export), 끝나면 지운다.
class PhotoSendItem implements SendItem {
  PhotoSendItem(this.asset, this.meta, {this.liveVideo = false});

  final AssetEntity asset;

  /// Live Photo 의 동영상 부분
  final bool liveVideo;

  @override
  final TransferFile meta;

  File? _file;

  @override
  Future<OpenedItem> open(int offset) async {
    final file = _file ??= await asset.loadFile(isOrigin: true, withSubtype: liveVideo);
    if (file == null) throw const FileSystemException('원본을 가져올 수 없음');
    return OpenedItem(file.openRead(offset), await file.length());
  }

  @override
  Future<void> release() async {
    final file = _file;
    _file = null;
    // 갤러리 원본 경로를 그대로 받은 경우는 절대 지우면 안 된다.
    // 앱 샌드박스 안으로 복사/export 된 임시파일만 정리한다.
    final isCopy = file != null &&
        (Platform.isIOS ? file.path.contains('/tmp/') : file.path.contains('com.sjpark.bulksend'));
    if (isCopy) {
      try {
        await file.delete();
      } on FileSystemException {
        // 이미 정리됨
      }
    }
  }
}

/// 안드로이드 SAF 처럼 경로 없이 content:// URI 로만 받은 파일.
/// 임의 위치 읽기가 안 되므로 이어받기 때는 앞부분을 읽어서 버린다.
class PickedSendItem implements SendItem {
  PickedSendItem(this.file, this.meta);

  final PlatformFile file;

  @override
  final TransferFile meta;

  @override
  Future<OpenedItem> open(int offset) async =>
      OpenedItem(skipBytes(file.readAsByteStream(), offset), meta.size);

  @override
  Future<void> release() async {}
}

/// 스트림 앞 [count] 바이트를 버린다
Stream<List<int>> skipBytes(Stream<List<int>> source, int count) async* {
  var left = count;
  await for (final chunk in source) {
    if (left >= chunk.length) {
      left -= chunk.length;
      continue;
    }
    yield left == 0 ? chunk : chunk.sublist(left);
    left = 0;
  }
}

/// 여러 파일 선택. 폴더 구조 없이 파일명만 유지한다.
Future<List<SendItem>> pickFiles() async {
  final picked = await FilePicker.pickFiles();
  final items = <SendItem>[];
  for (final f in picked) {
    if (f.path != null) {
      items.add(await FileSendItem.of(File(f.path!), f.name));
    } else {
      final size = await f.length();
      if (size == null) continue;
      items.add(PickedSendItem(
          f, TransferFile.create(relPath: f.name, size: size, mtime: 0, kind: FileKind.file)));
    }
  }
  return items;
}

const _folderChannel = MethodChannel('bulksend/folder');

/// 폴더 선택. 선택한 폴더 이름부터 시작하는 상대경로를 유지한다.
Future<List<SendItem>> pickFolder() async {
  final String? root;
  if (Platform.isIOS) {
    root = await _folderChannel.invokeMethod<String>('pickFolder');
  } else {
    // 다른 앱 폴더까지 dart:io 로 읽으려면 전체 파일 접근 권한이 필요하다
    if (!await Permission.manageExternalStorage.request().isGranted) {
      throw StateError('폴더를 읽으려면 "모든 파일 접근" 권한이 필요해요');
    }
    root = await FilePicker.getDirectoryPath();
  }
  if (root == null) return [];

  final base = p.dirname(root);
  final items = <SendItem>[];
  await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
    if (e is File) {
      items.add(await FileSendItem.of(e, p.split(p.relative(e.path, from: base)).join('/')));
    }
  }
  return items;
}

Future<void> requestPhotoAccess() async {
  final ps = await PhotoManager.requestPermissionExtend();
  if (!ps.isAuth) {
    throw StateError('사진 전체 접근 권한이 필요해요 (제한된 접근이면 설정에서 "모든 사진"으로 바꿔 주세요)');
  }
}

/// 앨범 목록. 첫 번째가 "전체(최근 항목)".
Future<List<AssetPathEntity>> listAlbums() async {
  await requestPhotoAccess();
  return PhotoManager.getAssetPathList(
    type: RequestType.common,
    filterOption: FilterOptionGroup(
      imageOption: const FilterOption(needTitle: true),
      videoOption: const FilterOption(needTitle: true),
    ),
  );
}

/// 앨범의 모든 사진/동영상을 전송 항목으로 만든다. Live Photo 는 사진 + MOV 두 항목.
/// 원본 크기는 export 전엔 정확히 모르므로 [kUnknownSize] 로 등록한다.
Future<List<SendItem>> loadAlbum(AssetPathEntity album,
    {void Function(int loaded, int total)? onProgress}) async {
  final total = await album.assetCountAsync;
  const pageSize = 500;
  final items = <SendItem>[];

  for (var page = 0; page * pageSize < total; page++) {
    final assets = await album.getAssetListPaged(page: page, size: pageSize);
    for (final a in assets) {
      final kind = switch (a.type) {
        AssetType.image => FileKind.photo,
        AssetType.video => FileKind.video,
        _ => null,
      };
      if (kind == null) continue;

      final title = a.title ?? await a.titleAsync;
      final mtime = a.createDateTime.millisecondsSinceEpoch;
      items.add(PhotoSendItem(a, _photoMeta(a, 'still', title, mtime, kind)));

      if (a.isLivePhoto) {
        final videoTitle = '${p.basenameWithoutExtension(title)}.MOV';
        items.add(PhotoSendItem(a, _photoMeta(a, 'live', videoTitle, mtime, FileKind.video),
            liveVideo: true));
      }
    }
    onProgress?.call(items.length, total);
  }
  return items;
}

/// 사진 ID 는 에셋 고유 ID 기반. 크기를 몰라도 다음 전송 때 같은 ID 가 나온다.
TransferFile _photoMeta(AssetEntity a, String part, String title, int mtime, FileKind kind) =>
    TransferFile(
      id: fileIdOf('asset:${a.id}:$part:$title', 0, mtime),
      relPath: title,
      size: kUnknownSize,
      mtime: mtime,
      kind: kind,
    );
