import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'models.dart';

/// 보낼 항목 하나. 실제 바이트는 전송 직전에 [open] 으로 가져온다.
/// (iOS 사진처럼 원본 준비에 시간이 걸리는 소스를 위해 지연 로딩)
abstract interface class SendItem {
  /// 크기를 모르면 size 가 [kUnknownSize] 일 수 있다. [open] 결과로 확정된다.
  TransferFile get meta;

  /// [offset] 바이트부터 읽는다. 읽을 수 없으면 예외를 던진다 → 실패 목록으로.
  Future<OpenedItem> open(int offset);

  /// 이 파일 전송이 끝났을 때(성공/실패) 호출. 임시로 꺼낸 파일 정리용.
  Future<void> release();
}

class OpenedItem {
  const OpenedItem(this.stream, this.size);

  final Stream<List<int>> stream;

  /// 전체 크기 (offset 과 무관)
  final int size;
}

enum SendState { idle, sending, paused, done, error }

enum SendError { wrongPin, connection, diskFull, unknown }

class SenderStats {
  SendState state = SendState.idle;
  SendError? error;
  int totalFiles = 0;
  int totalBytes = 0;
  int doneFiles = 0;
  int sentBytes = 0;
  String? currentFile;

  /// 소스에서 읽지 못해 건너뛴 파일
  final List<TransferFile> failed = [];
}

class _Fatal implements Exception {
  const _Fatal(this.error);
  final SendError error;
}

/// 보내는 쪽. [run] 을 다시 호출하면 새 세션으로 이어서 보낸다(이미 받은 파일은 건너뜀).
class Sender {
  Sender({
    required this.host,
    required this.pin,
    required this.senderId,
    required this.senderName,
    required this.items,
    this.port = kServerPort,
    this.batchSize = kFileBatchSize,
    this.concurrency = 3,
    this.maxAttempts = 5,
    this.retryBase = const Duration(seconds: 1),
  });

  final String host;
  final int port;
  final String pin;
  final String senderId;
  final String senderName;
  final List<SendItem> items;
  final int batchSize;
  final int concurrency;

  /// 진전 없이 연속으로 실패할 수 있는 횟수. 넘기면 paused.
  final int maxAttempts;
  final Duration retryBase;

  final SenderStats stats = SenderStats();
  final _changes = StreamController<void>.broadcast();

  /// 상태 변화, 파일 완료 시 알림. 바이트 진행률은 [stats] 를 주기적으로 읽는다.
  Stream<void> get changes => _changes.stream;

  HttpClient? _client;
  bool _pauseRequested = false;
  _Fatal? _fatal;

  Uri _url(String path) => Uri(scheme: 'http', host: host, port: port, path: path);

  void pause() {
    _pauseRequested = true;
    _client?.close(force: true);
  }

  Future<void> run() async {
    _pauseRequested = false;
    _fatal = null;
    stats
      ..state = SendState.sending
      ..error = null
      ..totalFiles = items.length
      ..totalBytes = items.fold(0, (s, e) => s + max(e.meta.size, 0))
      ..doneFiles = 0
      ..sentBytes = 0
      ..currentFile = null
      ..failed.clear();
    _emit();

    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final sid = await _startSession(client);
      for (var i = 0; i < items.length && !_stopped; i += batchSize) {
        final batch = items.sublist(i, min(i + batchSize, items.length));
        final statuses = await _register(client, sid, batch);
        final queue = <(SendItem, int)>[];
        for (final (idx, item) in batch.indexed) {
          final s = statuses[idx];
          if (s.state == FileState.done) {
            stats
              ..doneFiles += 1
              ..sentBytes += max(item.meta.size, 0);
          } else {
            stats.sentBytes += s.offset;
            queue.add((item, s.offset));
          }
        }
        _emit();
        await _uploadAll(client, sid, queue);
      }
      if (!_stopped) {
        await _request(client, 'POST', '/api/session/$sid/finish');
        stats
          ..state = SendState.done
          ..currentFile = null;
      }
    } on _Fatal catch (e) {
      _fatal ??= e;
    } on Object {
      if (!_pauseRequested) _fatal ??= const _Fatal(SendError.connection);
    } finally {
      client.close(force: true);
      _client = null;
    }

    if (_fatal != null) {
      stats
        ..error = _fatal!.error
        // PIN 오류는 다시 시도해도 소용없으니 error, 나머지는 재개 가능
        ..state = _fatal!.error == SendError.wrongPin ? SendState.error : SendState.paused;
    } else if (_pauseRequested) {
      stats.state = SendState.paused;
    }
    _emit();
  }

  bool get _stopped => _pauseRequested || _fatal != null;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<String> _startSession(HttpClient client) async {
    final (code, body) = await _request(client, 'POST', '/api/session',
        json: SessionRequest(
          pin: pin,
          senderId: senderId,
          senderName: senderName,
          totalFiles: stats.totalFiles,
          totalBytes: stats.totalBytes,
        ).toJson());
    if (code == 403) throw const _Fatal(SendError.wrongPin);
    if (code != 200) throw const _Fatal(SendError.connection);
    return body['sessionId'] as String;
  }

  Future<List<FileStatus>> _register(HttpClient client, String sid, List<SendItem> batch) async {
    final (code, body) = await _request(client, 'POST', '/api/session/$sid/files',
        json: batch.map((e) => e.meta.toJson()).toList());
    if (code != 200) throw const _Fatal(SendError.connection);
    return (body as List).map((e) => FileStatus.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _uploadAll(HttpClient client, String sid, List<(SendItem, int)> queue) async {
    var next = 0;
    Future<void> worker() async {
      while (!_stopped && next < queue.length) {
        final (item, offset) = queue[next++];
        try {
          await _uploadOne(client, sid, item, offset);
        } finally {
          await item.release();
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  }

  Future<void> _uploadOne(HttpClient client, String sid, SendItem item, int startOffset) async {
    final meta = item.meta;
    var serverOffset = startOffset;
    var pos = startOffset; // 이번 시도에서 흘려보낸 위치 (서버보다 앞설 수 있음)
    var attempts = 0;

    // 서버가 확인해 준 오프셋으로 진행률을 맞춘다
    void syncTo(int offset) {
      stats.sentBytes += offset - pos;
      pos = offset;
      if (offset > serverOffset) attempts = 0;
      serverOffset = offset;
    }

    while (!_stopped) {
      if (attempts >= maxAttempts) throw const _Fatal(SendError.connection);
      if (attempts > 0) {
        await Future<void>.delayed(retryBase * pow(2, attempts - 1));
        if (_stopped) return;
      }
      attempts++;

      OpenedItem opened;
      try {
        opened = await item.open(pos);
        if (meta.size != kUnknownSize && opened.size != meta.size) {
          throw StateError('size changed');
        }
      } catch (_) {
        stats
          ..failed.add(meta)
          ..sentBytes -= pos;
        _emit();
        return;
      }
      final size = opened.size;

      stats.currentFile = meta.relPath;
      try {
        final req = await client.put(host, port, '/api/session/$sid/upload/${meta.id}');
        req.headers
          ..set('X-Offset', '$pos')
          ..set('X-Size', '$size');
        req.contentLength = size - pos;
        await req.addStream(opened.stream.map((chunk) {
          pos += chunk.length;
          stats.sentBytes += chunk.length;
          return chunk;
        }));
        final res = await req.close();
        final body = jsonDecode(await utf8.decoder.bind(res).join());

        switch (res.statusCode) {
          case 200 when body['done'] == true:
            syncTo(size);
            stats.doneFiles += 1;
            _emit();
            return;
          case 200 || 409:
            syncTo(body['offset'] as int);
          case 404:
            throw const _Fatal(SendError.connection); // 받는 쪽이 재시작됨
          case 507:
            throw const _Fatal(SendError.diskFull);
          default:
            // 400/500: 서버 상태를 모르니 현재 위치로 다시 시도해 409 로 맞춘다
            break;
        }
      } on _Fatal catch (e) {
        _fatal ??= e;
        _client?.close(force: true);
        return;
      } catch (_) {
        // 네트워크 끊김 등: 다음 시도에서 서버 오프셋을 409 로 받아 맞춘다
        if (_stopped) return;
      }
    }
  }

  Future<(int, dynamic)> _request(HttpClient client, String method, String path,
      {Object? json}) async {
    final req = await client.openUrl(method, _url(path));
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(json)));
    }
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }
}
