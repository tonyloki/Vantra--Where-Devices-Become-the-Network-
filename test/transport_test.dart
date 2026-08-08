import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:vantra/core/networking/transport.dart';

void main() {
  group('Vantra Transport Models & Serialization Tests', () {
    test('ConnectionUpdate construct properties match', () {
      const update = ConnectionUpdate(
        endpointId: 'endpoint-123',
        status: ConnectionStatus.connecting,
        endpointName: 'Test Device',
        authenticationToken: '9999',
        isIncoming: true,
      );

      expect(update.endpointId, 'endpoint-123');
      expect(update.status, ConnectionStatus.connecting);
      expect(update.endpointName, 'Test Device');
      expect(update.authenticationToken, '9999');
      expect(update.isIncoming, true);
      expect(update.errorMessage, isNull);
    });

    test('DiscoveredPeer construct properties match', () {
      const peer = DiscoveredPeer(
        id: 'peer-abc',
        name: 'Alex Phone',
        serviceId: 'me.vantra.vantra',
      );

      expect(peer.id, 'peer-abc');
      expect(peer.name, 'Alex Phone');
      expect(peer.serviceId, 'me.vantra.vantra');
    });

    test('PayloadReceivedEvent payload byte encoding/decoding UTF-8 works', () {
      const msg = 'HELLO VANTRA';
      final encoded = Uint8List.fromList(utf8.encode(msg));

      final event = PayloadReceivedEvent(
        endpointId: 'endpoint-xyz',
        bytes: encoded,
      );

      final decoded = utf8.decode(event.bytes);
      expect(decoded, msg);
      expect(event.endpointId, 'endpoint-xyz');
    });
  });
}
