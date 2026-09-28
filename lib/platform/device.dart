import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 이 기기의 고유 ID. 받는 쪽이 보낸 기기별로 이어받기 기록을 나누는 데 쓴다.
Future<String> deviceId() async {
  final dir = await getApplicationSupportDirectory();
  final file = File(p.join(dir.path, 'device_id'));
  if (await file.exists()) return (await file.readAsString()).trim();
  final r = Random.secure();
  final id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  await file.create(recursive: true);
  await file.writeAsString(id);
  return id;
}

String deviceName() => Platform.isIOS ? 'iPhone' : 'Android';
