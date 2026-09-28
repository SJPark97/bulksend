import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'storage.dart';

/// 받기 화면에 보여줄 진행 상황
class ReceiverStats {
  SessionRequest? request;
  int doneFiles = 0;
  int receivedBytes = 0;
  String? currentFile;
  bool finished = false;
}

class _Session {
  _Session(this.senderId);

  final String senderId;
  final Map<String, TransferFile> files = {};
}

/// 받는 쪽 HTTP 서버.
///
/// 이어받기 상태는 보낸 기기별로 `workDir/<sender>/` 아래에 둔다.
///  - `done.log` : 완료한 파일 ID (한 줄에 하나, append-only)
///  - `<id>.part` : 받는 중인 파일
class ReceiverServer {
  ReceiverServer({
    required this.pin,
    required this.workDir,
    required this.storage,
  });

  final String pin;
  final Directory workDir;
  final ReceiveStorage storage;

  final ReceiverStats stats = ReceiverStats();
  final _changes = StreamController<void>.broadcast();

  /// 세션 시작, 파일 완료, 세션 종료 시 알림. 바이트 진행률은 [stats] 를 주기적으로 읽는다.
  Stream<void> get changes => _changes.stream;

  HttpServer? _server;
  final Map<String, _Session> _sessions = {};
  final Map<String, Set<String>> _doneBySender = {};
  final Set<String> _busy = {};
  final _random = Random.secure();

  int get port => _server!.port;

  Future<void> start({int port = kServerPort}) async {
    await workDir.create(recursive: true);
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    await _changes.close();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final seg = req.uri.pathSegments;
      if (req.method == 'POST' && seg.length == 2 && seg[1] == 'session') {
        return await _startSession(req);
      }
      if (seg.length >= 4 && seg[0] == 'api' && seg[1] == 'session') {
        final session = _sessions[seg[2]];
        if (session == null) return _reply(req, 404, {'error': 'unknown session'});
        final action = seg[3];
        if (req.method == 'POST' && action == 'files' && seg.length == 4) {
          return await _registerFiles(req, session);
        }
        if (req.method == 'PUT' && action == 'upload' && seg.length == 5) {
          return await _upload(req, session, seg[4]);
        }
        if (req.method == 'POST' && action == 'finish' && seg.length == 4) {
          stats.finished = true;
          stats.currentFile = null;
          _changes.add(null);
          return _reply(req, 200, {'doneFiles': stats.doneFiles});
        }
      }
      _reply(req, 404, {'error': 'not found'});
    } on FileSystemException catch (e) {
      // ENOSPC(28): 저장공간 부족
      final full = e.osError?.errorCode == 28;
      _reply(req, full ? 507 : 500, {'error': e.message});
    } catch (e) {
      _reply(req, 500, {'error': '$e'});
    }
  }

  Future<void> _startSession(HttpRequest req) async {
    final body = SessionRequest.fromJson(await _readJson(req) as Map<String, dynamic>);
    if (body.pin != pin) return _reply(req, 403, {'error': 'wrong pin'});

    final sid = List.generate(16, (_) => _random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    _sessions[sid] = _Session(body.senderId);
    await _loadDone(body.senderId);

    // 재접속이면 파일 목록 등록 단계에서 다시 집계된다
    stats
      ..request = body
      ..doneFiles = 0
      ..receivedBytes = 0
      ..currentFile = null
      ..finished = false;
    _changes.add(null);
    _reply(req, 200, {'sessionId': sid});
  }

  Future<void> _registerFiles(HttpRequest req, _Session session) async {
    final list = (await _readJson(req) as List)
        .map((e) => TransferFile.fromJson(e as Map<String, dynamic>));
    final done = _doneBySender[session.senderId]!;
    final result = <Map<String, dynamic>>[];

    for (final f in list) {
      session.files[f.id] = f;
      FileStatus status;
      if (done.contains(f.id)) {
        status = FileStatus(id: f.id, state: FileState.done, offset: max(f.size, 0));
        stats
          ..doneFiles += 1
          ..receivedBytes += max(f.size, 0);
      } else {
        final part = _partFile(session.senderId, f.id);
        var len = await part.exists() ? await part.length() : 0;
        if (f.size != kUnknownSize && len > f.size) {
          await part.delete();
          len = 0;
        }
        status = len > 0
            ? FileStatus(id: f.id, state: FileState.partial, offset: len)
            : FileStatus(id: f.id, state: FileState.fresh);
        stats.receivedBytes += len;
      }
      result.add(status.toJson());
    }
    _reply(req, 200, result);
  }

  Future<void> _upload(HttpRequest req, _Session session, String id) async {
    var meta = session.files[id];
    if (meta == null) return _reply(req, 404, {'error': 'unregistered file'});

    // 크기를 모르고 등록된 파일은 업로드 때 X-Size 로 확정한다
    final declared = int.tryParse(req.headers.value('X-Size') ?? '');
    if (meta.size == kUnknownSize) {
      if (declared == null || declared < 0) return _reply(req, 400, {'error': 'X-Size required'});
      meta = session.files[id] = meta.withSize(declared);
    } else if (declared != null && declared != meta.size) {
      return _reply(req, 400, {'error': 'size mismatch'});
    }

    final done = _doneBySender[session.senderId]!;
    if (done.contains(id)) return _reply(req, 200, {'done': true, 'offset': meta.size});

    final part = _partFile(session.senderId, id);
    var current = await part.exists() ? await part.length() : 0;
    if (current > meta.size) {
      await part.delete();
      current = 0;
    }
    final offset = int.tryParse(req.headers.value('X-Offset') ?? '');
    if (_busy.contains(id) || offset != current) {
      return _reply(req, 409, {'offset': current});
    }

    _busy.add(id);
    stats.currentFile = meta.relPath;
    final raf = await part.open(mode: FileMode.append);
    var written = current;
    var overflow = false;
    try {
      await for (final chunk in req) {
        if (written + chunk.length > meta.size) {
          overflow = true;
          break;
        }
        await raf.writeFrom(chunk);
        written += chunk.length;
        stats.receivedBytes += chunk.length;
      }
      if (overflow) {
        await raf.truncate(current);
        stats.receivedBytes -= written - current;
      }
    } finally {
      await raf.close();
      _busy.remove(id);
    }

    if (overflow) return _reply(req, 400, {'error': 'more bytes than size'});

    if (written == meta.size) {
      await storage.commit(part, meta);
      done.add(id);
      await _doneLog(session.senderId).writeAsString('$id\n', mode: FileMode.append, flush: true);
      stats.doneFiles += 1;
      _changes.add(null);
      return _reply(req, 200, {'done': true, 'offset': written});
    }
    _reply(req, 200, {'done': false, 'offset': written});
  }

  Directory _senderDir(String senderId) => Directory(p.join(
      workDir.path, sha1.convert(utf8.encode(senderId)).toString().substring(0, 16)));

  File _partFile(String senderId, String id) =>
      File(p.join(_senderDir(senderId).path, '$id.part'));

  File _doneLog(String senderId) => File(p.join(_senderDir(senderId).path, 'done.log'));

  Future<void> _loadDone(String senderId) async {
    if (_doneBySender.containsKey(senderId)) return;
    await _senderDir(senderId).create(recursive: true);
    final log = _doneLog(senderId);
    _doneBySender[senderId] = await log.exists()
        ? (await log.readAsLines()).where((l) => l.isNotEmpty).toSet()
        : <String>{};
  }

  Future<Object?> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    return text.isEmpty ? null : jsonDecode(text);
  }

  void _reply(HttpRequest req, int status, Object body) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    req.response.close();
  }
}
