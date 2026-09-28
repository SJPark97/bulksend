import 'package:flutter/material.dart';

void main() {
  runApp(const BulkSendApp());
}

class BulkSendApp extends StatelessWidget {
  const BulkSendApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'BulkSend',
      home: Scaffold(body: Center(child: Text('BulkSend'))),
    );
  }
}
