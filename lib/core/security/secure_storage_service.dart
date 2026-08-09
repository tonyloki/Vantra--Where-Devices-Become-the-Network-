import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vantra/core/utils/logger.dart';

class SecureStorageService {
  static const _keyIdentitySeed = 'vantra_identity_private_seed';
  final FlutterSecureStorage _storage;

  const SecureStorageService([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  /// Reads the 32-byte Ed25519 private key seed from Keystore-backed encrypted storage.
  /// Returns null if not found or if decryption fails.
  Future<List<int>?> getIdentityPrivateKeySeed() async {
    try {
      final hex = await _storage.read(key: _keyIdentitySeed);
      if (hex == null || hex.isEmpty) return null;
      return _hexDecode(hex);
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] Failed to read private key from secure storage, will regenerate', e, stack);
      return null;
    }
  }

  /// Writes the 32-byte Ed25519 private key seed to Keystore-backed encrypted storage.
  Future<void> saveIdentityPrivateKeySeed(List<int> seedBytes) async {
    try {
      final hex = seedBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await _storage.write(key: _keyIdentitySeed, value: hex);
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] Failed to save private key to secure storage', e, stack);
    }
  }

  /// Clears stored identity keys from secure storage
  Future<void> clearIdentityKeys() async {
    try {
      await _storage.delete(key: _keyIdentitySeed);
    } catch (_) {}
  }

  List<int> _hexDecode(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }
}
