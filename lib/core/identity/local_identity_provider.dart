import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'local_identity.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('sharedPreferencesProvider must be overridden in ProviderScope');
});

final localIdentityStateProvider = NotifierProvider<LocalIdentityNotifier, LocalIdentity>(() {
  return LocalIdentityNotifier();
});

class LocalIdentityNotifier extends Notifier<LocalIdentity> {
  static const _keyPeerId = 'vantra_peer_id';
  static const _keyDisplayName = 'vantra_display_name';

  @override
  LocalIdentity build() {
    final prefs = ref.watch(sharedPreferencesProvider);

    String? peerId = prefs.getString(_keyPeerId);
    if (peerId == null) {
      peerId = const Uuid().v4();
      prefs.setString(_keyPeerId, peerId);
    }

    String? displayName = prefs.getString(_keyDisplayName);
    if (displayName == null) {
      final randId = (1000 + (DateTime.now().millisecondsSinceEpoch % 9000)).toString();
      displayName = 'Vantra-$randId';
      prefs.setString(_keyDisplayName, displayName);
    }

    return LocalIdentity(peerId: peerId, displayName: displayName);
  }

  Future<void> updateDisplayName(String name) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_keyDisplayName, name);
    state = LocalIdentity(peerId: state.peerId, displayName: name);
  }
}
