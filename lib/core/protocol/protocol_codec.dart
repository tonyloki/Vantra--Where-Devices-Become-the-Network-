import 'dart:typed_data';
import 'protocol_message.dart';

/// Abstract interface defining wire and plaintext protocol codecs.
abstract interface class ProtocolCodec {
  /// Encodes a high-level domain envelope into raw Protobuf wire bytes.
  Uint8List encodeWireEnvelope(DomainWireEnvelope envelope);

  /// Decodes raw Protobuf wire bytes into a validated domain wire envelope.
  DomainWireEnvelope decodeWireEnvelope(Uint8List bytes);

  /// Encodes an authenticated domain plaintext payload into binary bytes.
  Uint8List encodePlaintext(DomainPlaintext plaintext);

  /// Decodes binary bytes into an authenticated domain plaintext payload.
  DomainPlaintext decodePlaintext(Uint8List bytes);
}
