import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/communication/transport/nearby_transport.dart';

final transportProvider = Provider<Transport>((ref) {
  return NearbyTransport();
});
