import 'dart:math';

import 'package:bulksend/core/connect_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('makeCode: IP 끝자리 3자리 + PIN 3자리', () {
    final code = makeCode('192.168.0.7', Random(1));
    expect(code, matches(RegExp(r'^007\d{3}$')));
  });

  test('parseCode: 내 IP 앞 3자리 + 코드 앞 3자리로 주소 계산', () {
    final t = parseCode('123 847', '192.168.0.55');
    expect(t, (host: '192.168.0.123', pin: '847'));
    expect(parseCode('005847', '172.20.10.2'), (host: '172.20.10.5', pin: '847'));
  });

  test('parseCode: 잘못된 코드는 null', () {
    expect(parseCode('12345', '192.168.0.1'), isNull);
    expect(parseCode('256847', '192.168.0.1'), isNull);
    expect(parseCode('abc847', '192.168.0.1'), isNull);
  });

  test('pickLanIpv4: 셀룰러 제외, 192.168 > 172.16~31 > 10 순서', () {
    expect(
        pickLanIpv4([
          ('rmnet_data0', '10.20.30.40'),
          ('wlan0', '10.0.0.5'),
          ('ap0', '192.168.43.1'),
        ]),
        '192.168.43.1');
    expect(
        pickLanIpv4([
          ('pdp_ip0', '10.1.2.3'),
          ('bridge100', '172.20.10.1'),
        ]),
        '172.20.10.1');
    expect(pickLanIpv4([('rmnet0', '10.1.2.3'), ('lo0', '127.0.0.1')]), isNull);
    expect(pickLanIpv4([('en0', '100.64.0.1')]), isNull);
  });
}
