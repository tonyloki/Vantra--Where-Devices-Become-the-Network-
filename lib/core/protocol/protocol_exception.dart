/// Exception thrown when a protocol packet fails validation or decoding.
class ProtocolValidationException implements Exception {
  final String message;
  final int? errorCode;

  const ProtocolValidationException(this.message, {this.errorCode});

  @override
  String toString() => 'ProtocolValidationException: $message${errorCode != null ? ' (code: $errorCode)' : ''}';
}
