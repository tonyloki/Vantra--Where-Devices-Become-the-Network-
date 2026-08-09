import 'package:cryptography/cryptography.dart';

class LocalIdentity {
  final String peerId;
  final String displayName;
  final String identityPublicKey;
  final String fingerprint;
  final SimpleKeyPair? keyPair;

  const LocalIdentity({
    required this.peerId,
    required this.displayName,
    required this.identityPublicKey,
    required this.fingerprint,
    this.keyPair,
  });

  LocalIdentity copyWith({
    String? peerId,
    String? displayName,
    String? identityPublicKey,
    String? fingerprint,
    SimpleKeyPair? keyPair,
  }) {
    return LocalIdentity(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      identityPublicKey: identityPublicKey ?? this.identityPublicKey,
      fingerprint: fingerprint ?? this.fingerprint,
      keyPair: keyPair ?? this.keyPair,
    );
  }
}
