import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vantra/core/utils/logger.dart';

class VantraPermissions {
  static const _channel = MethodChannel('me.vantra.vantra/device_info');

  /// Gets the Android SDK version from the native side.
  /// Defaults to 30 (Android 11) if the call fails or returns null.
  static Future<int> getAndroidSdkVersion() async {
    try {
      final int? sdkVersion = await _channel.invokeMethod<int>('getSdkVersion');
      return sdkVersion ?? 30;
    } catch (e, stackTrace) {
      VantraLogger.log('Failed to get Android SDK version, defaulting to 30', e, stackTrace);
      return 30;
    }
  }

  /// Checks if Location/GPS service is enabled on the device.
  static Future<bool> isLocationServiceEnabled() async {
    final status = await Permission.location.serviceStatus;
    VantraLogger.log('Location/GPS Service Status: ${status.name}');
    return status.isEnabled;
  }

  /// Requests the appropriate permissions based on the Android version.
  /// Returns true only if all requested permissions are granted.
  static Future<bool> requestNearbyPermissions() async {
    final sdkVersion = await getAndroidSdkVersion();
    VantraLogger.log('Detected Android SDK API Level: $sdkVersion');

    final List<Permission> permissionsToRequest = [];

    if (sdkVersion >= 33) {
      // Android 13+ requires nearby wifi devices, bluetooth scan/connect/advertise, and location for WiFi/BLE discovery
      permissionsToRequest.addAll([
        Permission.nearbyWifiDevices,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse,
      ]);
    } else if (sdkVersion >= 31) {
      // Android 12 requires bluetooth scan/connect/advertise and location
      permissionsToRequest.addAll([
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse,
      ]);
    } else {
      // Android 11 and below only require location (Bluetooth is an install-time permission)
      permissionsToRequest.add(Permission.locationWhenInUse);
    }

    VantraLogger.log('Requesting permissions: ${permissionsToRequest.map((p) => p.toString()).join(", ")}');
    final statuses = await permissionsToRequest.request();

    // Log explicit individual permission capability statuses
    if (sdkVersion >= 31) {
      VantraLogger.log('Permission Status -> Bluetooth Scan: ${statuses[Permission.bluetoothScan]?.name ?? "N/A"}');
      VantraLogger.log('Permission Status -> Bluetooth Connect: ${statuses[Permission.bluetoothConnect]?.name ?? "N/A"}');
      VantraLogger.log('Permission Status -> Bluetooth Advertise: ${statuses[Permission.bluetoothAdvertise]?.name ?? "N/A"}');
    }
    if (sdkVersion >= 33) {
      VantraLogger.log('Permission Status -> Nearby Wi-Fi Devices: ${statuses[Permission.nearbyWifiDevices]?.name ?? "N/A"}');
    }
    VantraLogger.log('Permission Status -> Location: ${statuses[Permission.locationWhenInUse]?.name ?? "N/A"}');

    final allGranted = statuses.values.every((status) => status.isGranted);
    VantraLogger.log('All requested permissions granted: $allGranted');

    return allGranted;
  }
}
