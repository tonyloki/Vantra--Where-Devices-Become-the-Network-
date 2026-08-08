/// Base exception class for all Vantra platform errors.
class VantraException implements Exception {
  final String message;
  final dynamic details;

  const VantraException(this.message, [this.details]);

  @override
  String toString() {
    if (details != null) {
      return 'VantraException: $message ($details)';
    }
    return 'VantraException: $message';
  }
}
