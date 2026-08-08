import 'package:flutter/foundation.dart';

/// Simple logger wrapper utility to print debug logs only in debug mode.
class VantraLogger {
  static void log(String message, [dynamic error, StackTrace? stackTrace]) {
    if (kDebugMode) {
      final time = DateTime.now().toIso8601String();
      if (error != null) {
        debugPrint('[$time] [VANTRA] $message - Error: $error');
        if (stackTrace != null) {
          debugPrint(stackTrace.toString());
        }
      } else {
        debugPrint('[$time] [VANTRA] $message');
      }
    }
  }
}
