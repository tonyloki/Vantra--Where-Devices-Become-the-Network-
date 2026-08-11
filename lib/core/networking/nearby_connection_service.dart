import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/utils/logger.dart';
import 'package:vantra/core/utils/permissions.dart';

enum NearbyServiceStatus {
  initializing,
  permissionsRequired,
  locationDisabled,
  ready,
  error,
}

class NearbyConnectionState {
  final NearbyServiceStatus status;
  final bool isAdvertising;
  final bool isDiscovering;
  final String? errorMessage;

  const NearbyConnectionState({
    required this.status,
    this.isAdvertising = false,
    this.isDiscovering = false,
    this.errorMessage,
  });

  NearbyConnectionState copyWith({
    NearbyServiceStatus? status,
    bool? isAdvertising,
    bool? isDiscovering,
    String? errorMessage,
    bool clearError = false,
  }) {
    return NearbyConnectionState(
      status: status ?? this.status,
      isAdvertising: isAdvertising ?? this.isAdvertising,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

final nearbyConnectionServiceProvider = NotifierProvider<NearbyConnectionNotifier, NearbyConnectionState>(() {
  return NearbyConnectionNotifier();
});

class NearbyConnectionNotifier extends Notifier<NearbyConnectionState> with WidgetsBindingObserver {
  bool _isInitializing = false;

  @override
  NearbyConnectionState build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
    });
    return const NearbyConnectionState(status: NearbyServiceStatus.initializing);
  }

  Future<void> initialize() async {
    if (state.status == NearbyServiceStatus.ready) {
      VantraLogger.log('[VANTRA][LIFECYCLE] NearbyConnectionService already ready, skipping initialize.');
      return;
    }
    if (_isInitializing) {
      VantraLogger.log('[VANTRA][LIFECYCLE] NearbyConnectionService is already initializing, skipping duplicate request.');
      return;
    }

    _isInitializing = true;
    VantraLogger.log('[VANTRA][LIFECYCLE] Initializing global NearbyConnectionService');
    state = state.copyWith(status: NearbyServiceStatus.initializing, clearError: true);

    try {
      final permissionsGranted = await VantraPermissions.requestNearbyPermissions();
      if (!permissionsGranted) {
        VantraLogger.log('[VANTRA][LIFECYCLE] Permissions denied for Nearby Connections');
        state = state.copyWith(status: NearbyServiceStatus.permissionsRequired);
        return;
      }

      final gpsEnabled = await VantraPermissions.isLocationServiceEnabled();
      if (!gpsEnabled) {
        VantraLogger.log('[VANTRA][LIFECYCLE] Location Services (GPS) are disabled');
        state = state.copyWith(status: NearbyServiceStatus.locationDisabled);
        return;
      }

      final localIdentity = ref.read(localIdentityStateProvider);
      final displayName = localIdentity.displayName.isNotEmpty
          ? localIdentity.displayName
          : 'VantraDevice';
      final advertisingName = '$displayName:${localIdentity.peerId}';

      final transport = ref.read(transportProvider);
      final peerDiscovery = ref.read(peerDiscoveryServiceProvider);

      try {
        VantraLogger.log('[VANTRA][LIFECYCLE] Starting advertising for $advertisingName');
        await transport.startAdvertising(advertisingName);
      } on PlatformException catch (e) {
        final isAlreadyAdvertising = e.code == '8001' ||
            e.message?.contains('STATUS_ALREADY_ADVERTISING') == true ||
            e.toString().contains('8001') ||
            e.toString().contains('STATUS_ALREADY_ADVERTISING');
        if (!isAlreadyAdvertising) {
          rethrow;
        }
        VantraLogger.log('[VANTRA][LIFECYCLE] Reconciled STATUS_ALREADY_ADVERTISING exception');
      }

      try {
        VantraLogger.log('[VANTRA][LIFECYCLE] Starting discovery for $advertisingName');
        await peerDiscovery.startDiscovery(localName: advertisingName);
      } on PlatformException catch (e) {
        final isAlreadyDiscovering = e.code == '8002' ||
            e.message?.contains('STATUS_ALREADY_DISCOVERING') == true ||
            e.toString().contains('8002') ||
            e.toString().contains('STATUS_ALREADY_DISCOVERING');
        if (!isAlreadyDiscovering) {
          rethrow;
        }
        VantraLogger.log('[VANTRA][LIFECYCLE] Reconciled STATUS_ALREADY_DISCOVERING exception');
      }

      state = state.copyWith(
        status: NearbyServiceStatus.ready,
        isAdvertising: true,
        isDiscovering: true,
        clearError: true,
      );
      VantraLogger.log('[VANTRA][LIFECYCLE] NearbyConnectionService fully ready');
    } catch (e, stackTrace) {
      VantraLogger.log('[VANTRA][LIFECYCLE] Error initializing NearbyConnectionService: $e', e, stackTrace);
      state = state.copyWith(
        status: NearbyServiceStatus.error,
        errorMessage: e.toString(),
      );
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> stopAll() async {
    VantraLogger.log('[VANTRA][LIFECYCLE] Stopping all Nearby operations');
    try {
      await ref.read(transportProvider).stopAdvertising();
    } catch (_) {}
    try {
      await ref.read(peerDiscoveryServiceProvider).stopDiscovery();
    } catch (_) {}

    state = state.copyWith(
      status: NearbyServiceStatus.initializing,
      isAdvertising: false,
      isDiscovering: false,
    );
  }

  Future<void> _suspendNearbyOperations() async {
    if (state.status == NearbyServiceStatus.ready) {
      VantraLogger.log('[VANTRA][LIFECYCLE] App backgrounded: Suspending Nearby operations to save battery');
      try {
        await ref.read(transportProvider).stopAdvertising();
      } catch (_) {}
      try {
        await ref.read(peerDiscoveryServiceProvider).stopDiscovery();
      } catch (_) {}
      state = state.copyWith(
        isAdvertising: false,
        isDiscovering: false,
      );
    }
  }

  Future<void> _resumeNearbyOperations() async {
    if (state.status == NearbyServiceStatus.ready) {
      VantraLogger.log('[VANTRA][LIFECYCLE] App foregrounded: Resuming Nearby operations');
      try {
        final localIdentity = ref.read(localIdentityStateProvider);
        final displayName = localIdentity.displayName.isNotEmpty
            ? localIdentity.displayName
            : 'VantraDevice';
        final advertisingName = '$displayName:${localIdentity.peerId}';

        if (!state.isAdvertising) {
          try {
            await ref.read(transportProvider).startAdvertising(advertisingName);
          } on PlatformException catch (e) {
            final isAlreadyAdvertising = e.code == '8001' ||
                e.message?.contains('STATUS_ALREADY_ADVERTISING') == true ||
                e.toString().contains('8001') ||
                e.toString().contains('STATUS_ALREADY_ADVERTISING');
            if (!isAlreadyAdvertising) {
              rethrow;
            }
          }
        }

        if (!state.isDiscovering) {
          try {
            await ref.read(peerDiscoveryServiceProvider).startDiscovery(localName: advertisingName);
          } on PlatformException catch (e) {
            final isAlreadyDiscovering = e.code == '8002' ||
                e.message?.contains('STATUS_ALREADY_DISCOVERING') == true ||
                e.toString().contains('8002') ||
                e.toString().contains('STATUS_ALREADY_DISCOVERING');
            if (!isAlreadyDiscovering) {
              rethrow;
            }
          }
        }

        state = state.copyWith(
          isAdvertising: true,
          isDiscovering: true,
        );
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (this.state.status != NearbyServiceStatus.ready) {
        initialize();
      } else {
        _resumeNearbyOperations();
      }
    } else if (state == AppLifecycleState.paused) {
      _suspendNearbyOperations();
    }
  }
}
