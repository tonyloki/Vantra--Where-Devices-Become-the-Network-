import 'dart:convert';
import 'dart:typed_data';

class CanonicalEncoder {
  static const String domainSeparator = 'VANTRA_HANDSHAKE_DOMAIN';

  /// Serializes handshake parameters into deterministic binary bytes with explicit domain separation.
  static Uint8List encodeHandshakeTranscript({
    required int protocolVersion,
    required String peerId,
    required String displayName,
    required List<int> identityPublicKeyBytes,
    required List<int> ephemeralPublicKeyBytes,
  }) {
    final builder = BytesBuilder();

    // 1. Domain separator UTF-8 bytes
    builder.add(utf8.encode(domainSeparator));

    // 2. Protocol version (uint32 big-endian)
    final versionBytes = ByteData(4)..setUint32(0, protocolVersion, Endian.big);
    builder.add(versionBytes.buffer.asUint8List());

    // 3. peerId (length-prefixed string)
    final peerIdBytes = utf8.encode(peerId);
    final peerIdLen = ByteData(2)..setUint16(0, peerIdBytes.length, Endian.big);
    builder.add(peerIdLen.buffer.asUint8List());
    builder.add(peerIdBytes);

    // 4. displayName (length-prefixed string)
    final displayNameBytes = utf8.encode(displayName);
    final displayNameLen = ByteData(2)..setUint16(0, displayNameBytes.length, Endian.big);
    builder.add(displayNameLen.buffer.asUint8List());
    builder.add(displayNameBytes);

    // 5. identityPublicKey (length-prefixed bytes)
    final idKeyLen = ByteData(2)..setUint16(0, identityPublicKeyBytes.length, Endian.big);
    builder.add(idKeyLen.buffer.asUint8List());
    builder.add(identityPublicKeyBytes);

    // 6. ephemeralPublicKey (length-prefixed bytes)
    final ephKeyLen = ByteData(2)..setUint16(0, ephemeralPublicKeyBytes.length, Endian.big);
    builder.add(ephKeyLen.buffer.asUint8List());
    builder.add(ephemeralPublicKeyBytes);

    return builder.toBytes();
  }
}
