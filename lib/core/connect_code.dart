import 'dart:io';
import 'dart:math';

/// 6자리 인증번호 = 받는 폰 IPv4 마지막 옥텟(3자리) + 랜덤 PIN(3자리).
/// 두 폰이 같은 /24 대역에 있다고 가정하고, 보내는 쪽은 자기 IP 앞 3옥텟을 붙여 주소를 만든다.
String makeCode(String myIpv4, Random random) {
  final last = myIpv4.split('.').last.padLeft(3, '0');
  final pin = random.nextInt(1000).toString().padLeft(3, '0');
  return '$last$pin';
}

/// 공백은 무시한다. 형식이 틀리면 null.
({String host, String pin})? parseCode(String code, String myIpv4) {
  final digits = code.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^\d{6}$').hasMatch(digits)) return null;
  final last = int.parse(digits.substring(0, 3));
  if (last > 255) return null;
  final prefix = myIpv4.split('.').take(3).join('.');
  return (host: '$prefix.$last', pin: digits.substring(3));
}

/// 셀룰러/VPN 등 로컬 전송에 쓸 수 없는 인터페이스
final _excluded = RegExp(r'^(rmnet|ccmni|pdp_ip|v4-rmnet|dummy|tun|utun|ipsec|lo)');

/// (인터페이스 이름, 주소) 목록에서 로컬 전송용 사설 IPv4 를 고른다.
/// 핫스팟 폰은 셀룰러에도 10.x 가 붙을 수 있어서 192.168 → 172.16~31 → 10 순으로 우선한다.
String? pickLanIpv4(List<(String, String)> candidates) {
  int? rank(String ip) {
    final o = ip.split('.').map(int.parse).toList();
    if (o[0] == 192 && o[1] == 168) return 0;
    if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return 1;
    if (o[0] == 10) return 2;
    return null;
  }

  final usable = [
    for (final (name, ip) in candidates)
      if (!_excluded.hasMatch(name) && rank(ip) != null) (rank(ip)!, ip),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return usable.isEmpty ? null : usable.first.$2;
}

Future<String?> findLanIpv4() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  return pickLanIpv4([
    for (final i in interfaces)
      for (final a in i.addresses) (i.name, a.address),
  ]);
}
