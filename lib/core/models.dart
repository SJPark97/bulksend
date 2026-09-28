import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 받는 쪽 HTTP 서버 포트 (고정)
const int kServerPort = 53420;

/// 파일 목록 등록 시 한 번에 보내는 개수
const int kFileBatchSize = 1000;

/// 저장 위치를 가르는 기준. photo/video 는 갤러리, file 은 파일 폴더로 간다.
enum FileKind { photo, video, file }

/// 같은 파일이면 앱을 다시 켜도 같은 ID가 나오도록 경로·크기·수정시각으로 만든다.
String fileIdOf(String relPath, int size, int mtime) =>
    sha1.convert(utf8.encode('$relPath\u0000$size\u0000$mtime')).toString();

class TransferFile {
  const TransferFile({
    required this.id,
    required this.relPath,
    required this.size,
    required this.mtime,
    required this.kind,
  });

  factory TransferFile.create({
    required String relPath,
    required int size,
    required int mtime,
    required FileKind kind,
  }) =>
      TransferFile(
        id: fileIdOf(relPath, size, mtime),
        relPath: relPath,
        size: size,
        mtime: mtime,
        kind: kind,
      );

  factory TransferFile.fromJson(Map<String, dynamic> j) => TransferFile(
        id: j['id'] as String,
        relPath: j['relPath'] as String,
        size: j['size'] as int,
        mtime: j['mtime'] as int,
        kind: FileKind.values.byName(j['kind'] as String),
      );

  final String id;

  /// '/' 구분 상대경로. 폴더 구조 유지용.
  final String relPath;
  final int size;

  /// 수정시각 (epoch ms)
  final int mtime;
  final FileKind kind;

  Map<String, dynamic> toJson() => {
        'id': id,
        'relPath': relPath,
        'size': size,
        'mtime': mtime,
        'kind': kind.name,
      };

  @override
  bool operator ==(Object other) =>
      other is TransferFile &&
      other.id == id &&
      other.relPath == relPath &&
      other.size == size &&
      other.mtime == mtime &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, relPath, size, mtime, kind);
}

/// done: 이미 받음 / partial: offset 까지 받음 / fresh: 처음부터
enum FileState { done, partial, fresh }

class FileStatus {
  const FileStatus({required this.id, required this.state, this.offset = 0});

  factory FileStatus.fromJson(Map<String, dynamic> j) => FileStatus(
        id: j['id'] as String,
        state: FileState.values.byName(j['state'] as String),
        offset: j['offset'] as int,
      );

  final String id;
  final FileState state;
  final int offset;

  Map<String, dynamic> toJson() =>
      {'id': id, 'state': state.name, 'offset': offset};

  @override
  bool operator ==(Object other) =>
      other is FileStatus &&
      other.id == id &&
      other.state == state &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(id, state, offset);
}

class SessionRequest {
  const SessionRequest({
    required this.pin,
    required this.senderId,
    required this.senderName,
    required this.totalFiles,
    required this.totalBytes,
  });

  factory SessionRequest.fromJson(Map<String, dynamic> j) => SessionRequest(
        pin: j['pin'] as String,
        senderId: j['senderId'] as String,
        senderName: j['senderName'] as String,
        totalFiles: j['totalFiles'] as int,
        totalBytes: j['totalBytes'] as int,
      );

  final String pin;

  /// 보내는 기기 고유 ID. 받는 쪽은 이 값별로 이어받기 기록을 나눈다.
  final String senderId;
  final String senderName;
  final int totalFiles;
  final int totalBytes;

  Map<String, dynamic> toJson() => {
        'pin': pin,
        'senderId': senderId,
        'senderName': senderName,
        'totalFiles': totalFiles,
        'totalBytes': totalBytes,
      };

  @override
  bool operator ==(Object other) =>
      other is SessionRequest &&
      other.pin == pin &&
      other.senderId == senderId &&
      other.senderName == senderName &&
      other.totalFiles == totalFiles &&
      other.totalBytes == totalBytes;

  @override
  int get hashCode =>
      Object.hash(pin, senderId, senderName, totalFiles, totalBytes);
}
