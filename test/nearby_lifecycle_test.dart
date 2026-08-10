import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vantra/communication/transport/nearby_transport.dart';
import 'package:vantra/core/networking/nearby_connection_service.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'test_fakes.dart';

class MockTransportWithErrors extends FakeTransport {
  bool simulateAdvertisingError = false;
  bool simulateDiscoveryError = false;
  int startAdvertisingCallCount = 0;
  int startDiscoveryCallCount = 0;

  @override
  Future<void> startAdvertising(String localName) async {
    startAdvertisingCallCount++;
    if (simulateAdvertisingError) {
      throw PlatformException(
        code: '8001',
        message: 'STATUS_ALREADY_ADVERTISING',
      );
    }
    isAdvertising = true;
  }

  @override
  Future<void> startDiscovery(String localName) async {
    startDiscoveryCallCount++;
    if (simulateDiscoveryError) {
      throw PlatformException(
        code: '8002',
        message: 'STATUS_ALREADY_DISCOVERING',
      );
    }
    isDiscovering = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('nearby_connections');
  const permissionChannel = MethodChannel('flutter.baseflow.com/permissions/methods');
  const deviceInfoChannel = MethodChannel('me.vantra.vantra/device_info');
  bool mockShouldThrowAlreadyAdvertising = false;
  bool mockShouldThrowAlreadyDiscovering = false;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'startAdvertising') {
        if (mockShouldThrowAlreadyAdvertising) {
          throw PlatformException(code: '8001', message: 'STATUS_ALREADY_ADVERTISING');
        }
        return true;
      }
      if (methodCall.method == 'startDiscovery') {
        if (mockShouldThrowAlreadyDiscovering) {
          throw PlatformException(code: '8002', message: 'STATUS_ALREADY_DISCOVERING');
        }
        return true;
      }
      return true;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkServiceStatus') {
        return 1; // ServiceStatus.enabled
      }
      if (methodCall.method == 'requestPermissions') {
        final List<dynamic> permissions = methodCall.arguments;
        final Map<dynamic, dynamic> results = {};
        for (final p in permissions) {
          results[p] = 1; // PermissionStatus.granted
        }
        return results;
      }
      if (methodCall.method == 'checkPermissionStatus') {
        return 1; // PermissionStatus.granted
      }
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceInfoChannel, (MethodCall methodCall) async {
      if (methodCall.method == 'getSdkVersion') {
        return 30;
      }
      return null;
    });
  });

  group('NearbyTransport Idempotency & Platform Exception Reconciler', () {
    late NearbyTransport transport;

    setUp(() {
      transport = NearbyTransport();
      mockShouldThrowAlreadyAdvertising = false;
      mockShouldThrowAlreadyDiscovering = false;
    });

    test('startAdvertising twice does not fail and returns normally', () async {
      await transport.startAdvertising('DeviceA');
      
      // Second call, normally would crash on native with 8001
      mockShouldThrowAlreadyAdvertising = true;
      await expectLater(transport.startAdvertising('DeviceA'), completes);
    });

    test('startDiscovery twice does not fail and returns normally', () async {
      await transport.startDiscovery('DeviceA');
      
      // Second call, normally would crash on native with 8002
      mockShouldThrowAlreadyDiscovering = true;
      await expectLater(transport.startDiscovery('DeviceA'), completes);
    });
  });

  group('NearbyConnectionService Lifecycle & State Reconciliation', () {
    late MockTransportWithErrors mockTransport;
    late ProviderContainer container;
    late AppDatabase testDb;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      mockTransport = MockTransportWithErrors();
      testDb = AppDatabase.forTesting(NativeDatabase.memory());

      final fakeSecureStorage = FakeSecureStorageService();
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(mockTransport),
          appDatabaseProvider.overrideWithValue(testDb),
          secureStorageServiceProvider.overrideWithValue(fakeSecureStorage),
        ],
      );

      await container.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
    });

    tearDown(() async {
      await testDb.close();
      container.dispose();
    });

    test('Initializes successfully when transport behaves normally', () async {
      final serviceNotifier = container.read(nearbyConnectionServiceProvider.notifier);
      await serviceNotifier.initialize();

      final state = container.read(nearbyConnectionServiceProvider);
      expect(state.status, NearbyServiceStatus.ready);
      expect(state.isAdvertising, isTrue);
      expect(state.isDiscovering, isTrue);
    });

    test('Reconciles state on STATUS_ALREADY_ADVERTISING and completes successfully', () async {
      mockTransport.simulateAdvertisingError = true;

      final serviceNotifier = container.read(nearbyConnectionServiceProvider.notifier);
      
      // Under the hood, NearbyConnectionService should catch 8001 and mark isAdvertising = true
      await serviceNotifier.initialize();

      final state = container.read(nearbyConnectionServiceProvider);
      expect(state.status, NearbyServiceStatus.ready);
      expect(state.isAdvertising, isTrue);
      expect(state.isDiscovering, isTrue);
    });

    test('Bypasses redundant concurrent initialization calls', () async {
      final serviceNotifier = container.read(nearbyConnectionServiceProvider.notifier);
      
      // Trigger multiple initializations concurrently
      final Future<void> firstInit = serviceNotifier.initialize();
      final Future<void> secondInit = serviceNotifier.initialize();
      
      await Future.wait([firstInit, secondInit]);

      // Verify transport only had one initial advertising/discovery call
      expect(mockTransport.startAdvertisingCallCount, 1);
      expect(mockTransport.startDiscoveryCallCount, 1);
    });

    test('Handles AppLifecycleState Resumed/Paused flow without duplicated runs', () async {
      final serviceNotifier = container.read(nearbyConnectionServiceProvider.notifier);
      await serviceNotifier.initialize();

      // Trigger app backgrounded (paused)
      serviceNotifier.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future.delayed(const Duration(milliseconds: 50));
      var state = container.read(nearbyConnectionServiceProvider);
      expect(state.isAdvertising, isFalse);
      expect(state.isDiscovering, isFalse);

      // Trigger app foregrounded (resumed)
      serviceNotifier.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future.delayed(const Duration(milliseconds: 50));
      state = container.read(nearbyConnectionServiceProvider);
      expect(state.isAdvertising, isTrue);
      expect(state.isDiscovering, isTrue);

      // Trigger resumed again when already ready
      serviceNotifier.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(mockTransport.startAdvertisingCallCount, 2); // 1 from initial + 1 from resume
    });
  });
}
