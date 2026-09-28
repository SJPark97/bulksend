import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/connect_code.dart';
import '../core/sender.dart';
import '../platform/device.dart';
import '../platform/send_sources.dart';
import 'format.dart';

class SendPage extends StatefulWidget {
  const SendPage({super.key});

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> {
  final _codeCtrl = TextEditingController();
  final List<SendItem> _items = [];
  String? _loading;
  String? _message;
  Sender? _sender;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    _sender?.pause();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _add(Future<List<SendItem>> Function() pick) async {
    setState(() {
      _message = null;
      _loading = '목록 만드는 중…';
    });
    try {
      final picked = await pick();
      // 같은 파일을 두 번 고르면 한 번만
      final ids = _items.map((e) => e.meta.id).toSet();
      _items.addAll(picked.where((e) => ids.add(e.meta.id)));
    } catch (e) {
      _message = e is StateError ? e.message : '$e';
    }
    if (mounted) setState(() => _loading = null);
  }

  Future<List<SendItem>> _pickAlbum({required bool allPhotos}) async {
    final albums = await listAlbums();
    if (albums.isEmpty) return [];
    AssetPathEntity? album = allPhotos ? albums.first : null;
    if (!allPhotos) {
      if (!mounted) return [];
      album = await showDialog<AssetPathEntity>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('앨범 선택'),
          children: [
            for (final a in albums)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, a),
                child: FutureBuilder<int>(
                  future: a.assetCountAsync,
                  builder: (_, snap) => Text('${a.name}  (${snap.data ?? '…'})'),
                ),
              ),
          ],
        ),
      );
    }
    if (album == null) return [];
    return loadAlbum(album, onProgress: (loaded, total) {
      if (mounted) setState(() => _loading = '사진 목록 불러오는 중… $loaded / $total');
    });
  }

  Future<void> _start() async {
    final ip = await findLanIpv4();
    if (ip == null) {
      setState(() => _message = '와이파이 또는 핫스팟에 연결되어 있지 않아요');
      return;
    }
    final target = parseCode(_codeCtrl.text, ip);
    if (target == null) {
      setState(() => _message = '인증번호 6자리를 확인해 주세요');
      return;
    }

    final sender = Sender(
      host: target.host,
      pin: target.pin,
      senderId: await deviceId(),
      senderName: deviceName(),
      items: List.of(_items),
    );
    setState(() {
      _sender = sender;
      _message = null;
    });
    _ticker ??= Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (mounted) setState(() {});
    });
    await _run();
  }

  Future<void> _run() async {
    final sender = _sender!;
    await sender.run();
    if (!mounted) return;
    if (sender.stats.error == SendError.wrongPin) {
      // 인증번호를 다시 입력하도록 처음 화면으로
      setState(() {
        _sender = null;
        _message = '인증번호가 틀렸어요';
      });
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('보내기')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _sender == null ? _setup(context) : _progress(context),
      ),
    );
  }

  Widget _setup(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _loading != null;
    final totalKnown = _items.fold<int>(0, (s, e) => s + (e.meta.size > 0 ? e.meta.size : 0));

    return ListView(
      children: [
        Text('1. 보낼 항목 고르기', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.photo_library),
              label: const Text('사진 전체'),
              onPressed: busy ? null : () => _add(() => _pickAlbum(allPhotos: true)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.photo_album),
              label: const Text('앨범'),
              onPressed: busy ? null : () => _add(() => _pickAlbum(allPhotos: false)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.insert_drive_file),
              label: const Text('파일'),
              onPressed: busy ? null : () => _add(pickFiles),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.folder),
              label: const Text('폴더'),
              onPressed: busy ? null : () => _add(pickFolder),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (busy) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 4),
          Text(_loading!),
        ] else
          Row(
            children: [
              Expanded(
                child: Text(
                  '선택: ${_items.length}개'
                  '${totalKnown > 0 ? ' (${formatBytes(totalKnown)}+)' : ''}',
                ),
              ),
              if (_items.isNotEmpty)
                TextButton(
                  onPressed: () => setState(_items.clear),
                  child: const Text('비우기'),
                ),
            ],
          ),
        const Divider(height: 40),
        Text('2. 받는 폰의 인증번호 입력', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 6),
          textAlign: TextAlign.center,
          decoration: const InputDecoration(hintText: '000000', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        FilledButton(
          onPressed: busy || _items.isEmpty ? null : _start,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Text('전송 시작', style: TextStyle(fontSize: 18)),
          ),
        ),
      ],
    );
  }

  Widget _progress(BuildContext context) {
    final theme = Theme.of(context);
    final s = _sender!.stats;
    final sending = s.state == SendState.sending;

    final status = switch (s.state) {
      SendState.sending => '보내는 중… 화면을 켜 두세요',
      SendState.done => '✅ 전송 완료',
      SendState.paused => switch (s.error) {
          SendError.connection => '연결이 끊겼어요. 같은 네트워크인지 확인하고 재개하세요',
          SendError.diskFull => '받는 폰 저장공간이 부족해요',
          _ => '일시정지됨',
        },
      _ => '오류가 났어요',
    };

    return ListView(
      children: [
        Text(status, style: theme.textTheme.titleMedium),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: s.totalFiles == 0 ? null : s.doneFiles / s.totalFiles),
        const SizedBox(height: 8),
        Text('파일 ${s.doneFiles} / ${s.totalFiles}'),
        Text(s.totalBytes > 0
            ? '${formatBytes(s.sentBytes)} / ${formatBytes(s.totalBytes)}+'
            : formatBytes(s.sentBytes)),
        if (sending && s.currentFile != null)
          Text(s.currentFile!, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 24),
        if (sending)
          OutlinedButton(onPressed: _sender!.pause, child: const Text('일시정지'))
        else if (s.state == SendState.paused)
          FilledButton(onPressed: _run, child: const Text('재개')),
        if (s.failed.isNotEmpty) ...[
          const Divider(height: 40),
          Text('읽지 못한 파일 ${s.failed.length}개', style: TextStyle(color: theme.colorScheme.error)),
          for (final f in s.failed.take(200)) Text(f.relPath, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}
