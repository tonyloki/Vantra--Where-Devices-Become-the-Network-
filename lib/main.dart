import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/networking/nearby_connection_service.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/themes/vantra_theme.dart';
import 'package:vantra/core/utils/logger.dart';

import 'features/onboarding/onboarding_page.dart';
import 'features/home/home_page.dart';
import 'features/peers/nearby_peers_page.dart';
import 'features/peers/contacts_page.dart';
import 'features/peers/peer_profile_page.dart';
import 'features/messaging/chat_page.dart';
import 'features/profile/profile_page.dart';
import 'features/poc/poc_page.dart';
import 'features/peers/verify_identity_page.dart';
import 'features/peers/show_my_qr_page.dart';
import 'features/messaging/create_group_page.dart';
import 'features/messaging/group_chat_page.dart';
import 'package:vantra/core/calls/call_session.dart';
import 'package:vantra/core/calls/call_provider.dart';
import 'features/calls/incoming_call_page.dart';
import 'features/calls/active_call_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runZoned(() {
    runApp(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const VantraApp(),
      ),
    );
  }, zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {
      parent.print(zone, line);
      if (line.contains('[VANTRA]')) {
        VantraLogger.printAndLog(line);
      }
    },
  ));
}

final GoRouter _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const SplashPage(),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingPage(),
    ),
    GoRoute(
      path: '/home',
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: '/nearby',
      builder: (context, state) => const NearbyPeersPage(),
    ),
    GoRoute(
      path: '/contacts',
      builder: (context, state) => const ContactsPage(),
    ),
    GoRoute(
      path: '/peer/:peerId',
      builder: (context, state) {
        final peerId = state.pathParameters['peerId'] ?? 'unknown';
        return PeerProfilePage(peerId: peerId);
      },
    ),
    GoRoute(
      path: '/chat/:peerId',
      builder: (context, state) {
        final peerId = state.pathParameters['peerId'] ?? 'unknown';
        return ChatPage(peerId: peerId);
      },
    ),
    GoRoute(
      path: '/create_group',
      builder: (context, state) => const CreateGroupPage(),
    ),
    GoRoute(
      path: '/group_chat/:groupId',
      builder: (context, state) {
        final groupId = state.pathParameters['groupId'] ?? 'unknown';
        return GroupChatPage(groupId: groupId);
      },
    ),
    GoRoute(
      path: '/profile',
      builder: (context, state) => const ProfilePage(),
    ),
    GoRoute(
      path: '/poc',
      builder: (context, state) => const PocPage(),
    ),
    GoRoute(
      path: '/peers/:peerId/verify',
      builder: (context, state) {
        final peerId = state.pathParameters['peerId'] ?? 'unknown';
        return VerifyIdentityPage(peerId: peerId);
      },
    ),
    GoRoute(
      path: '/peers/:peerId/my-qr',
      builder: (context, state) {
        final peerId = state.pathParameters['peerId'] ?? 'unknown';
        return ShowMyQrPage(peerId: peerId);
      },
    ),
  ],
);

class VantraApp extends StatelessWidget {
  const VantraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'VANTRA',
      theme: VantraTheme.darkTheme,
      routerConfig: _router,
      builder: (context, child) {
        return GlobalConnectionListener(child: child!);
      },
    );
  }
}

class GlobalConnectionListener extends ConsumerWidget {
  final Widget child;
  const GlobalConnectionListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(messagingStateProvider);
    final request = state.activeConnectionRequest;
    final mismatch = state.identityMismatchRequest;
    final callSession = ref.watch(callStateProvider);

    return Stack(
      children: [
        child,
        if (callSession != null)
          Positioned.fill(
            child: callSession.status == CallStatus.incoming
                ? IncomingCallPage(peerId: callSession.peerId)
                : ActiveCallPage(session: callSession),
          ),
        if (request != null && callSession == null)
          Positioned.fill(
            child: Material(
              color: Colors.black87,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Card(
                      color: VantraTheme.surface.withValues(alpha: 0.9),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        side: const BorderSide(color: VantraTheme.primary, width: 1.5),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.cell_tower_rounded,
                              size: 48,
                              color: VantraTheme.primaryAccent,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              request.isIncoming
                                  ? 'Connection Request'
                                  : 'Outgoing Request',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: VantraTheme.textPrimary,
                                decoration: TextDecoration.none,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Device: ${request.endpointName}',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: VantraTheme.textPrimary, decoration: TextDecoration.none),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Establish secure offline pairing connection',
                              style: TextStyle(fontSize: 12, color: VantraTheme.textSecondary, decoration: TextDecoration.none),
                              textAlign: TextAlign.center,
                            ),
                            if (request.authenticationToken != null) ...[
                              const SizedBox(height: 20),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                decoration: BoxDecoration(
                                  color: VantraTheme.background,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white10),
                                ),
                                child: Text(
                                  'Pairing Code: ${request.authenticationToken}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 2,
                                    color: VantraTheme.amberWarning,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 24),
                            if (state.connectionStatus == ConnectionStatus.accepting)
                              const Column(
                                children: [
                                  CircularProgressIndicator(color: VantraTheme.primary),
                                  SizedBox(height: 12),
                                  Text(
                                    'Establishing connection...',
                                    style: TextStyle(
                                      color: VantraTheme.textSecondary,
                                      fontSize: 14,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                ],
                              )
                            else
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () {
                                        ref.read(messagingStateProvider.notifier).rejectConnectionRequest(request.endpointId);
                                      },
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: VantraTheme.redBlocked,
                                        side: const BorderSide(color: VantraTheme.redBlocked),
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                      ),
                                      child: const Text('REJECT'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton(
                                      onPressed: () {
                                        ref.read(messagingStateProvider.notifier).acceptConnectionRequest(request.endpointId);
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: VantraTheme.greenVerified,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                      ),
                                      child: const Text('ACCEPT'),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
        else if (mismatch != null && callSession == null)
          Positioned.fill(
            child: Material(
              color: Colors.black87,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Card(
                      color: VantraTheme.surface.withValues(alpha: 0.9),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        side: const BorderSide(color: VantraTheme.redBlocked, width: 1.5),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              size: 48,
                              color: VantraTheme.redBlocked,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Security change detected',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: VantraTheme.textPrimary,
                                decoration: TextDecoration.none,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'The identity of this device does not match the identity you previously trusted.',
                              style: TextStyle(fontSize: 14, color: VantraTheme.textSecondary, decoration: TextDecoration.none),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () {
                                      ref.read(messagingStateProvider.notifier).rejectIdentityChange(mismatch.peerId);
                                    },
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: VantraTheme.redBlocked,
                                      side: const BorderSide(color: VantraTheme.redBlocked),
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                    ),
                                    child: const Text('KEEP BLOCKED'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {
                                      ref.read(messagingStateProvider.notifier).acceptIdentityChange(mismatch.peerId, mismatch.newPublicKey);
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: VantraTheme.greenVerified,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                    ),
                                    child: const Text('VERIFY AGAIN'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class SplashPage extends ConsumerStatefulWidget {
  const SplashPage({super.key});

  @override
  ConsumerState<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends ConsumerState<SplashPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  bool _animationCompleted = false;
  bool _hasRouted = false;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.8, curve: Curves.easeOutQuart),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.8, curve: Curves.easeOutQuart),
      ),
    );

    _controller.forward().then((_) {
      if (mounted) {
        setState(() {
          _animationCompleted = true;
        });
        _evalRouting();
      }
    });

    // Start Nearby connections initialization in background
    Future.microtask(() {
      ref.read(nearbyConnectionServiceProvider.notifier).initialize();
    });

    // Bounded timeout: if still initializing after 2.5 seconds, navigate anyway
    _timeoutTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && !_hasRouted) {
        final state = ref.read(nearbyConnectionServiceProvider);
        if (state.status == NearbyServiceStatus.initializing) {
          VantraLogger.log('[VANTRA][LIFECYCLE] Splash timeout reached. Routing to home/onboarding in background.');
          _routeToNextPage();
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  void _evalRouting() {
    if (!_animationCompleted || _hasRouted) return;

    final connectionState = ref.read(nearbyConnectionServiceProvider);
    if (connectionState.status == NearbyServiceStatus.ready) {
      _routeToNextPage();
    }
  }

  void _routeToNextPage() {
    _hasRouted = true;
    final onboardingCompleted = ref.read(onboardingCompletedProvider);
    if (onboardingCompleted) {
      context.go('/home');
    } else {
      context.go('/onboarding');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen to nearby connection state updates
    ref.listen<NearbyConnectionState>(nearbyConnectionServiceProvider, (previous, next) {
      if (next.status == NearbyServiceStatus.ready && _animationCompleted) {
        _evalRouting();
      }
    });

    final connectionState = ref.watch(nearbyConnectionServiceProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0E13),
      body: Stack(
        children: [
          Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Opacity(
                  opacity: _fadeAnimation.value,
                  child: Transform.scale(
                    scale: _scaleAnimation.value,
                    child: child,
                  ),
                );
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LogoPulseWidget(
                    child: Image.asset(
                      'lib/Assets/Logo.png',
                      width: 140,
                      height: 140,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'VANTRA',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 6,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Where Devices Become the Network.',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade500,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 60,
            child: Center(
              child: _buildStatusWidget(connectionState),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusWidget(NearbyConnectionState state) {
    switch (state.status) {
      case NearbyServiceStatus.initializing:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.deepPurpleAccent),
          ),
        );
      case NearbyServiceStatus.permissionsRequired:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Permissions required to connect with nearby devices.',
              style: TextStyle(color: Colors.redAccent, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                ref.read(nearbyConnectionServiceProvider.notifier).initialize();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: const Text('GRANT PERMISSIONS'),
            ),
          ],
        );
      case NearbyServiceStatus.locationDisabled:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Please enable Location Services (GPS) to discover devices.',
              style: TextStyle(color: Colors.amberAccent, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                ref.read(nearbyConnectionServiceProvider.notifier).initialize();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: const Text('RETRY'),
            ),
          ],
        );
      case NearbyServiceStatus.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Initialization error: ${state.errorMessage}',
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                ref.read(nearbyConnectionServiceProvider.notifier).initialize();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey.shade800,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: const Text('RETRY'),
            ),
          ],
        );
      case NearbyServiceStatus.ready:
        return const SizedBox.shrink();
    }
  }
}

class LogoPulseWidget extends StatefulWidget {
  final Widget child;
  const LogoPulseWidget({super.key, required this.child});

  @override
  State<LogoPulseWidget> createState() => _LogoPulseWidgetState();
}

class _LogoPulseWidgetState extends State<LogoPulseWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Ring 1
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final progress = _controller.value;
            return Container(
              width: 140 + (progress * 80),
              height: 140 + (progress * 80),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: VantraTheme.primary.withValues(alpha: (1.0 - progress) * 0.3),
                  width: 1.5,
                ),
              ),
            );
          },
        ),
        // Ring 2
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final progress = (_controller.value + 0.5) % 1.0;
            return Container(
              width: 140 + (progress * 80),
              height: 140 + (progress * 80),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: VantraTheme.primary.withValues(alpha: (1.0 - progress) * 0.15),
                  width: 1.5,
                ),
              ),
            );
          },
        ),
        widget.child,
      ],
    );
  }
}
