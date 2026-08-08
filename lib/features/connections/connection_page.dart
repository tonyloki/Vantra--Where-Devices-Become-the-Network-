import 'package:flutter/material.dart';

class ConnectionPage extends StatelessWidget {
  const ConnectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Requests'),
      ),
      body: const Center(
        child: Text(
          'Connection requests not implemented yet.',
          style: TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}
