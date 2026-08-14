import 'package:flutter/foundation.dart';

/// Simple logger wrapper utility to print debug logs only in debug mode.
class VantraLogger {
  static void Function(String)? onLog;

  static void log(String message, [dynamic error, StackTrace? stackTrace]) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    final String logLine;
    if (error != null) {
      logLine = '[VANTRA] $message - Error: $error';
      if (kDebugMode) {
        debugPrint('[$time] $logLine');
        if (stackTrace != null) {
          debugPrint(stackTrace.toString());
        }
      }
    } else {
      logLine = '[VANTRA] $message';
      if (kDebugMode) {
        debugPrint('[$time] $logLine');
      }
    }
    printAndLog('[$time] $logLine');
  }

  static void printAndLog(String line) {
    final hasTimestamp = RegExp(r'^\[\d{2}:\d{2}:\d{2}\]').hasMatch(line);
    final formattedLine = hasTimestamp 
        ? line 
        : '[${DateTime.now().toIso8601String().substring(11, 19)}] $line';
    
    onLog?.call(formattedLine);
  }
}
