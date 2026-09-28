import 'dart:async';
import 'dart:io';

import 'package:bulksend/core/models.dart';
import 'package:bulksend/core/receiver_server.dart';
import 'package:bulksend/core/sender.dart';
import 'package:bulksend/core/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 메모리 데이터를 보내는 테스트용 항목. [failAfter] 바이트 뒤에 [failTimes] 번 끊긴다.
class MemItem implements SendItem {
  MemItem(String relPath, this.data, {this.failAfter, this.failTimes = 0, bool unknownSize = false})
      : meta = TransferFile(
            id: fileIdOf(relPath, 0, 1700000000000),
            relPath: relPath,
            size: unknownSize ? kUnknownSize : data.length,
            mtime: 1700000000000,
            kind: FileKind.file);

  @override
  final TransferFile meta;
  final List<int> data;
  final int? failAfter;
  int failTimes;
  int opens = 0;
  int releases = 0;

  @override
  Future<OpenedItem> open(int offset) async {
    opens++;
    final rest = data.sublist(offset);
    if (failAfter == null || failTimes <= 0) return OpenedItem(Stream.value(rest), data.length);
    failTimes--;
    final cut = (failAfter! - offset).clamp(0, rest.length);
    return OpenedItem((() async* {
      yield rest.sublist(0, cut);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      throw const SocketException('simulated drop');
    })(), data.length);
  }

  @override
  Future<void> release() async => releases++;
}

class BrokenItem implements SendItem {
  @override
  final meta = TransferFile.create(relPath: 'broken.bin', size: 5, mtime: 1, kind: FileKind.file);

  @override
  Future<OpenedItem> open(int offset) async => throw const FileSystemException('gone');

  @override
  Future<void> release() async {}
}

List<int> bytes(int n, int seed) => List<int>.generate(n, (i) => (i * 7 + seed) % 256);

void main() {
  late Directory tmp;
  late Directory out;
  late ReceiverServer server;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bulksend_sender');
    out = Directory(p.join(tmp.path, 'out'));
    server = ReceiverServer(
        pin: '847', workDir: Directory(p.join(tmp.path, 'work')), storage: FolderStorage(out));
    await server.start(port: 0);
  });

  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  Sender makeSender(List<SendItem> items, {String pin = '847', int batchSize = kFileBatchSize}) =>
      Sender(
        host: '127.0.0.1',
        port: server.port,
        pin: pin,
        senderId: 'dev-1',
        senderName: 'Test',
        items: items,
        batchSize: batchSize,
        retryBase: const Duration(milliseconds: 5),
      );

  Future<List<int>> saved(String rel) => File(p.join(out.path, rel)).readAsBytes();

  test('여러 배치로 나눠 전부 전송', () async {
    final items = [for (var i = 0; i < 25; i++) MemItem('d/$i.bin', bytes(1000 + i, i))];
    final sender = makeSender(items, batchSize: 10);
    await sender.run();

    expect(sender.stats.state, SendState.done);
    expect(sender.stats.doneFiles, 25);
    expect(sender.stats.sentBytes, items.fold<int>(0, (s, e) => s + e.data.length));
    for (final it in items) {
      expect(await saved(it.meta.relPath), it.data);
    }
  });

  test('크기를 모르고 등록해도 업로드 때 확정되어 저장, 끊겨도 이어받기', () async {
    final data = bytes(150000, 9);
    final item = MemItem('photo.heic', data, unknownSize: true, failAfter: 70000, failTimes: 1);
    final sender = makeSender([item]);
    await sender.run();

    expect(sender.stats.state, SendState.done);
    expect(await saved('photo.heic'), data);
    expect(item.releases, 1);

    // 다시 보내면 열지 않고 건너뜀
    final again = MemItem('photo.heic', data, unknownSize: true);
    await makeSender([again]).run();
    expect(again.opens, 0);
  });

  test('PIN이 틀리면 wrongPin 에러', () async {
    final sender = makeSender([MemItem('a', bytes(3, 0))], pin: '000');
    await sender.run();
    expect(sender.stats.state, SendState.error);
    expect(sender.stats.error, SendError.wrongPin);
  });

  test('전송 중 끊기면 서버 오프셋부터 이어서 보냄', () async {
    final data = bytes(200000, 3);
    final item = MemItem('big.bin', data, failAfter: 120000, failTimes: 2);
    final sender = makeSender([item]);
    await sender.run();

    expect(sender.stats.state, SendState.done);
    expect(await saved('big.bin'), data);
    expect(item.opens, greaterThanOrEqualTo(3));
  });

  test('재시도 횟수를 넘기면 paused, resume 하면 완료', () async {
    final data = bytes(50000, 5);
    final item = MemItem('flaky.bin', data, failAfter: 10000, failTimes: 100);
    final sender = makeSender([item]);
    await sender.run();
    expect(sender.stats.state, SendState.paused);
    expect(sender.stats.error, SendError.connection);

    item.failTimes = 0;
    await sender.run();
    expect(sender.stats.state, SendState.done);
    expect(await saved('flaky.bin'), data);
  });

  test('이미 받은 파일은 다시 보내지 않음', () async {
    final a = MemItem('a.bin', bytes(100, 1));
    await makeSender([a]).run();

    final a2 = MemItem('a.bin', bytes(100, 1));
    final b = MemItem('b.bin', bytes(100, 2));
    final sender = makeSender([a2, b]);
    await sender.run();

    expect(sender.stats.state, SendState.done);
    expect(sender.stats.doneFiles, 2);
    expect(a2.opens, 0);
    expect(await saved('b.bin'), b.data);
  });

  test('읽을 수 없는 파일은 실패 목록에 넣고 나머지는 계속', () async {
    final ok = MemItem('ok.bin', bytes(10, 1));
    final sender = makeSender([BrokenItem(), ok]);
    await sender.run();

    expect(sender.stats.state, SendState.done);
    expect(sender.stats.failed.map((f) => f.relPath), ['broken.bin']);
    expect(await saved('ok.bin'), ok.data);
  });

  test('pause 하면 멈추고 resume 으로 끝까지', () async {
    final items = [for (var i = 0; i < 40; i++) MemItem('p/$i.bin', bytes(20000, i))];
    final sender = makeSender(items);
    final run = sender.run();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    sender.pause();
    await run;
    expect(sender.stats.state, anyOf(SendState.paused, SendState.done));

    await sender.run();
    expect(sender.stats.state, SendState.done);
    for (final it in items) {
      expect(await saved(it.meta.relPath), it.data);
    }
  });
}
