import 'package:flutter/material.dart';

import 'ui/receive_page.dart';
import 'ui/send_page.dart';

void main() {
  runApp(const BulkSendApp());
}

class BulkSendApp extends StatelessWidget {
  const BulkSendApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BulkSend',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    Widget big(String label, IconData icon, Widget page) => SizedBox(
          width: double.infinity,
          height: 120,
          child: FilledButton.icon(
            icon: Icon(icon, size: 36),
            label: Text(label, style: const TextStyle(fontSize: 24)),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('BulkSend')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            big('보내기', Icons.upload, const SendPage()),
            const SizedBox(height: 24),
            big('받기', Icons.download, const ReceivePage()),
            const SizedBox(height: 32),
            const Text('두 폰을 같은 와이파이(또는 한쪽 핫스팟)에 연결하세요.'),
          ],
        ),
      ),
    );
  }
}
