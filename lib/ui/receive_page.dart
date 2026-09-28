import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/connect_code.dart';
import '../core/receiver_server.dart';
import '../platform/receive_storage.dart';
import 'format.dart';

class ReceivePage extends StatefulWidget {
  const ReceivePage({super.key});

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> with WidgetsBindingObserver {
  ReceiverServer? _server;
  String? _code;
  String? _folderPath;
  String? _error;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 받기 화면에 있는 동안은 대기 중에도 화면을 켜 둔다
    WakelockPlus.enable();
    _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable();
      _server?.ensureListening();
    }
  }

  Future<void> _start() async {
    try {
      final setup = await prepareReceive();
      final ip = await findLanIpv4();
      if (ip == null) throw StateError('와이파이 또는 핫스팟에 연결되어 있지 않아요');

      final code = makeCode(ip, Random.secure());
      final server = ReceiverServer(
        pin: code.substring(3),
        workDir: setup.workDir,
        storage: setup.storage,
      );
      await server.start();
      if (!mounted) return await server.stop();

      setState(() {
        _server = server;
        _code = code;
        _folderPath = setup.folderPath;
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 300), (_) => setState(() {}));
    } catch (e) {
      if (mounted) setState(() => _error = e is StateError ? e.message : '$e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _ticker?.cancel();
    _server?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('받기')),
      body: Padding(padding: const EdgeInsets.all(24), child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!, textAlign: TextAlign.center));
    final server = _server;
    if (server == null) return const Center(child: CircularProgressIndicator());

    final s = server.stats;
    final req = s.request;
    final theme = Theme.of(context);

    return ListView(
      children: [
        const Text('보내는 폰에 이 번호를 입력하세요', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(
          formatCode(_code!),
          textAlign: TextAlign.center,
          style: theme.textTheme.displayLarge?.copyWith(
              fontWeight: FontWeight.bold, letterSpacing: 4, fontFeatures: const []),
        ),
        const SizedBox(height: 8),
        const Text('이 화면을 켜 둔 채로 기다려 주세요', textAlign: TextAlign.center),
        const Divider(height: 48),
        if (req == null)
          const Text('연결 대기 중…', textAlign: TextAlign.center)
        else ...[
          Text('${req.senderName}에서 받는 중', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: req.totalFiles == 0 ? null : s.doneFiles / req.totalFiles,
          ),
          const SizedBox(height: 8),
          Text('파일 ${s.doneFiles} / ${req.totalFiles}'),
          // 사진은 크기를 모르고 등록돼 합계에서 빠지므로, 넘어서면 받은 양만 보여준다
          Text(req.totalBytes >= s.receivedBytes
              ? '${formatBytes(s.receivedBytes)} / ${formatBytes(req.totalBytes)}'
              : formatBytes(s.receivedBytes)),
          if (s.currentFile != null && !s.finished)
            Text(s.currentFile!, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (s.finished)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('✅ 전송 완료', style: theme.textTheme.titleLarge),
            ),
        ],
        const Divider(height: 48),
        Text('사진·동영상 → 갤러리(사진 앱)\n파일 → $_folderPath',
            style: theme.textTheme.bodySmall),
      ],
    );
  }
}
