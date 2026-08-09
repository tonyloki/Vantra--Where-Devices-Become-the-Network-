import 'package:flutter_test/flutter_test.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/peers/peer_discovery_service.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport fakeTransport;
  late PeerDiscoveryService discoveryService;

  setUp(() {
    fakeTransport = FakeTransport();
    discoveryService = PeerDiscoveryService(fakeTransport);
  });

  tearDown(() {
    discoveryService.dispose();
  });

  group('PeerDiscoveryService Tests', () {
    test('Start and stop discovery triggers transport and streams status', () async {
      expect(discoveryService.isDiscovering, isFalse);

      final statusFuture = discoveryService.isDiscoveringStream.first;
      await discoveryService.startDiscovery();
      expect(await statusFuture, isTrue);
      expect(fakeTransport.isDiscovering, isTrue);

      await discoveryService.stopDiscovery();
      expect(fakeTransport.isDiscovering, isFalse);
    });

    test('Discovered peers are deduplicated and mapped', () async {
      await discoveryService.startDiscovery();

      // Trigger discovered peers from transport
      fakeTransport.triggerDiscoveredPeers([
        const DiscoveredPeer(id: 'EP1', name: 'Vantra-Alpha', serviceId: 'vantra'),
        const DiscoveredPeer(id: 'EP2', name: 'Vantra-Beta', serviceId: 'vantra'),
      ]);

      var peers = await discoveryService.discoveredPeersStream.first;
      expect(peers.length, 2);
      expect(peers[0].endpointName, 'Vantra-Alpha');
      expect(peers[1].endpointName, 'Vantra-Beta');

      // Duplicate update with EP2 removed
      fakeTransport.triggerDiscoveredPeers([
        const DiscoveredPeer(id: 'EP1', name: 'Vantra-Alpha', serviceId: 'vantra'),
      ]);

      peers = await discoveryService.discoveredPeersStream.first;
      expect(peers.length, 1);
      expect(peers[0].endpointId, 'EP1');
    });

    test('Connecting to endpoint updates isConnecting state', () async {
      await discoveryService.startDiscovery();

      fakeTransport.triggerDiscoveredPeers([
        const DiscoveredPeer(id: 'EP1', name: 'Vantra-Target', serviceId: 'vantra'),
      ]);

      await discoveryService.discoveredPeersStream.first;

      final expectFuture = expectLater(
        discoveryService.discoveredPeersStream,
        emits(predicate<List<DiscoveredNearbyPeer>>((peers) => peers.any((p) => p.isConnecting))),
      );

      await discoveryService.connect('EP1');
      await expectFuture;
    });
  });
}
