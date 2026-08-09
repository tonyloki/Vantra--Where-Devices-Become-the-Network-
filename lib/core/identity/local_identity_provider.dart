import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/security/secure_storage_service.dart';
import 'local_identity.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('sharedPreferencesProvider must be overridden in ProviderScope');
});

final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService();
});

final secureStorageServiceProvider = Provider<SecureStorageService>((ref) {
  return const SecureStorageService();
});

final localIdentityStateProvider = NotifierProvider<LocalIdentityNotifier, LocalIdentity>(() {
  return LocalIdentityNotifier();
});

class LocalIdentityNotifier extends Notifier<LocalIdentity> {
  static const _keyPeerId = 'vantra_peer_id';
  static const _keyDisplayName = 'vantra_display_name';
  static const _keyPublicKey = 'vantra_identity_public_key';
  static const _keyFingerprint = 'vantra_identity_fingerprint';

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

    final cachedPubKey = prefs.getString(_keyPublicKey) ?? '';
    final cachedFingerprint = prefs.getString(_keyFingerprint) ?? '';

    Future.microtask(() => ensureKeysLoaded());

    return LocalIdentity(
      peerId: peerId,
      displayName: displayName,
      identityPublicKey: cachedPubKey,
      fingerprint: cachedFingerprint,
    );
  }

  Future<void> ensureKeysLoaded() async {
    final secureStorage = ref.read(secureStorageServiceProvider);
    final cryptoService = ref.read(cryptoServiceProvider);
    final prefs = ref.read(sharedPreferencesProvider);

    final seed = await secureStorage.getIdentityPrivateKeySeed();
    SimpleKeyPair keyPair;

    if (seed != null) {
      try {
        keyPair = await cryptoService.identityKeyPairFromSeed(seed);
      } catch (_) {
        keyPair = await cryptoService.generateIdentityKeyPair();
        final seedData = await keyPair.extract();
        await secureStorage.saveIdentityPrivateKeySeed(seedData.bytes);
      }
    } else {
      keyPair = await cryptoService.generateIdentityKeyPair();
      final seedData = await keyPair.extract();
      await secureStorage.saveIdentityPrivateKeySeed(seedData.bytes);
    }

    final pub = await keyPair.extractPublicKey();
    final pubHex = pub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final fingerprint = await cryptoService.computeFingerprint(pub.bytes);

    await prefs.setString(_keyPublicKey, pubHex);
    await prefs.setString(_keyFingerprint, fingerprint);

    state = state.copyWith(
      identityPublicKey: pubHex,
      fingerprint: fingerprint,
      keyPair: keyPair,
    );
  }

  Future<void> updateDisplayName(String name) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_keyDisplayName, name);
    state = state.copyWith(displayName: name);
  }
}
