import 'dart:convert';
import 'dart:io';

import 'package:bulksend/core/models.dart';
import 'package:bulksend/core/receiver_server.dart';
import 'package:bulksend/core/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory out;
  late ReceiverServer server;
  final client = HttpClient();

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<(int, dynamic)> send(String method, String path,
      {Object? json, List<int>? bytes, Map<String, String>? headers}) async {
    final req = await client.openUrl(method, url(path));
    headers?.forEach(req.headers.set);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    } else if (bytes != null) {
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  Future<String> startSession({String pin = '847', String sender = 'dev-1'}) async {
    final (code, body) = await send('POST', '/api/session',
        json: SessionRequest(
          pin: pin,
          senderId: sender,
          senderName: 'Test',
          totalFiles: 1,
          totalBytes: 10,
        ).toJson());
    expect(code, 200);
    return body['sessionId'] as String;
  }

  Future<List<FileStatus>> register(String sid, List<TransferFile> files) async {
    final (code, body) = await send('POST', '/api/session/$sid/files',
        json: files.map((f) => f.toJson()).toList());
    expect(code, 200);
    return (body as List)
        .map((e) => FileStatus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  final data = List<int>.generate(10, (i) => i);
  final file = TransferFile.create(
      relPath: 'dir/a.bin', size: 10, mtime: 1700000000000, kind: FileKind.file);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bulksend_test');
    out = Directory(p.join(tmp.path, 'out'));
    server = ReceiverServer(
      pin: '847',
      workDir: Directory(p.join(tmp.path, 'work')),
      storage: FolderStorage(out),
    );
    await server.start(port: 0);
  });

  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  test('PIN이 틀리면 403', () async {
    final (code, _) = await send('POST', '/api/session',
        json: const SessionRequest(
          pin: '000',
          senderId: 'dev-1',
          senderName: 'x',
          totalFiles: 0,
          totalBytes: 0,
        ).toJson());
    expect(code, 403);
  });

  test('모르는 세션이면 404', () async {
    final (code, _) = await send('POST', '/api/session/nope/files', json: []);
    expect(code, 404);
  });

  test('한 번에 업로드하면 폴더 구조 유지해서 저장', () async {
    final sid = await startSession();
    expect((await register(sid, [file])).single.state, FileState.fresh);

    final (code, body) = await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: data, headers: {'X-Offset': '0'});
    expect(code, 200);
    expect(body['done'], true);

    final saved = File(p.join(out.path, 'dir', 'a.bin'));
    expect(await saved.readAsBytes(), data);
    expect((await saved.lastModified()).millisecondsSinceEpoch, file.mtime);
  });

  test('부분 업로드 후 오프셋부터 이어받기', () async {
    final sid = await startSession();
    await register(sid, [file]);

    var (code, body) = await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: data.sublist(0, 4), headers: {'X-Offset': '0'});
    expect(code, 200);
    expect(body, {'done': false, 'offset': 4});

    // 새 세션(재접속)에서도 부분 상태가 보인다
    final sid2 = await startSession();
    expect((await register(sid2, [file])).single,
        FileStatus(id: file.id, state: FileState.partial, offset: 4));

    (code, body) = await send('PUT', '/api/session/$sid2/upload/${file.id}',
        bytes: data.sublist(4), headers: {'X-Offset': '4'});
    expect(code, 200);
    expect(body['done'], true);
    expect(await File(p.join(out.path, 'dir', 'a.bin')).readAsBytes(), data);
  });

  test('오프셋이 다르면 409와 현재 오프셋', () async {
    final sid = await startSession();
    await register(sid, [file]);
    await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: data.sublist(0, 4), headers: {'X-Offset': '0'});

    final (code, body) = await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: data.sublist(2), headers: {'X-Offset': '2'});
    expect(code, 409);
    expect(body['offset'], 4);
  });

  test('크기보다 많이 보내면 400', () async {
    final sid = await startSession();
    await register(sid, [file]);
    final (code, _) = await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: [...data, 1, 2], headers: {'X-Offset': '0'});
    expect(code, 400);
  });

  test('이미 받은 파일은 다음 세션에서 done', () async {
    final sid = await startSession();
    await register(sid, [file]);
    await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: data, headers: {'X-Offset': '0'});

    final sid2 = await startSession();
    expect((await register(sid2, [file])).single.state, FileState.done);
  });

  test('다른 기기가 같은 파일을 보내면 이어받기 기록을 공유하지 않음', () async {
    final sid = await startSession();
    await register(sid, [file]);
    await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: data, headers: {'X-Offset': '0'});

    final other = await startSession(sender: 'dev-2');
    expect((await register(other, [file])).single.state, FileState.fresh);
  });

  test('통계: 이미 받은 파일과 부분 바이트 반영', () async {
    final sid = await startSession();
    await register(sid, [file]);
    await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: data.sublist(0, 3), headers: {'X-Offset': '0'});
    expect(server.stats.receivedBytes, 3);
    expect(server.stats.doneFiles, 0);

    await send('PUT', '/api/session/$sid/upload/${file.id}',
        bytes: data.sublist(3), headers: {'X-Offset': '3'});
    expect(server.stats.receivedBytes, 10);
    expect(server.stats.doneFiles, 1);

    final (code, _) = await send('POST', '/api/session/$sid/finish');
    expect(code, 200);
    expect(server.stats.finished, true);
  });

  test('크기 모름(-1)으로 등록하면 X-Size 필수, 이후 크기 불일치는 400', () async {
    final unknown = TransferFile(
        id: 'u1', relPath: 'p.heic', size: kUnknownSize, mtime: 1, kind: FileKind.photo);
    final sid = await startSession();
    expect((await register(sid, [unknown])).single.state, FileState.fresh);

    var (code, _) = await send('PUT', '/api/session/$sid/upload/u1',
        bytes: data.sublist(0, 4), headers: {'X-Offset': '0'});
    expect(code, 400);

    (code, _) = await send('PUT', '/api/session/$sid/upload/u1',
        bytes: data.sublist(0, 4), headers: {'X-Offset': '0', 'X-Size': '10'});
    expect(code, 200);

    (code, _) = await send('PUT', '/api/session/$sid/upload/u1',
        bytes: data.sublist(4), headers: {'X-Offset': '4', 'X-Size': '11'});
    expect(code, 400);

    final (code2, body) = await send('PUT', '/api/session/$sid/upload/u1',
        bytes: data.sublist(4), headers: {'X-Offset': '4', 'X-Size': '10'});
    expect(code2, 200);
    expect(body['done'], true);
  });

  test('ensureListening: 살아 있으면 그대로, 세션 유지', () async {
    final sid = await startSession();
    await server.ensureListening();
    final (code, _) = await send('POST', '/api/session/$sid/files', json: []);
    expect(code, 200);
  });

  test('같은 이름 파일을 동시에 받아도 덮어쓰지 않고, 완료 기록도 빠짐없이 남김', () async {
    final files = [
      for (var i = 0; i < 30; i++)
        TransferFile(id: 'dup$i', relPath: 'same.bin', size: 10, mtime: 1, kind: FileKind.file),
    ];
    final sid = await startSession();
    await register(sid, files);
    await Future.wait([
      for (final f in files)
        send('PUT', '/api/session/$sid/upload/${f.id}', bytes: data, headers: {'X-Offset': '0'}),
    ]);
    expect(out.listSync().whereType<File>().length, 30);

    // 서버를 새로 띄워도(앱 재시작) 완료 기록이 모두 남아 있어야 한다
    await server.stop();
    server = ReceiverServer(
        pin: '847', workDir: Directory(p.join(tmp.path, 'work')), storage: FolderStorage(out));
    await server.start(port: 0);
    final sid2 = await startSession();
    final states = (await register(sid2, files)).map((s) => s.state).toSet();
    expect(states, {FileState.done});
  });
}
