import 'dart:convert';
import 'package:crypto/crypto.dart';

class SafetyNumberService {
  /// Computes a 25-digit Safety Number from two public keys (hex strings).
  /// The calculation is commutative (returns the same value regardless of key order).
  static String computeSafetyNumber(String localKeyHex, String remoteKeyHex) {
    // 1. Sort the public keys lexicographically to ensure commutativity
    final keys = [localKeyHex.toLowerCase(), remoteKeyHex.toLowerCase()]..sort();
    final sortedConcat = keys.join(':');

    // 2. Compute SHA-512 hash over the key concatenation
    final bytesToHash = utf8.encode('VANTRA_SAFETY_NUMBER:$sortedConcat');
    final hashBytes = sha512.convert(bytesToHash).bytes;

    // 3. Divide the first 30 bytes of hash into 5 groups of 6 bytes
    final groups = <String>[];
    for (int i = 0; i < 5; i++) {
      final offset = i * 6;
      final groupBytes = hashBytes.sublist(offset, offset + 6);
      
      // Interpret 6 bytes as a 48-bit big-endian integer
      int value = 0;
      for (int b in groupBytes) {
        value = (value << 8) | (b & 0xFF);
      }

      // mod 100,000 to get a 5-digit number
      final groupVal = value % 100000;
      groups.add(groupVal.toString().padLeft(5, '0'));
    }

    // 4. Return as space-separated groups
    return groups.join(' ');
  }
}
