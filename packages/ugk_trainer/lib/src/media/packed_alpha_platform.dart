import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The small native texture contract. No per-frame position or pixel channel.
abstract class PackedAlphaPlatform {
  bool get isSupported;
  Stream<Map<Object?, Object?>> get events;
  Future<({int playerId, int textureId})> create(String asset);
  Future<Object?> command(int playerId, String type, [Object? value]);
}

class MethodChannelPackedAlphaPlatform implements PackedAlphaPlatform {
  static const _methods = MethodChannel('ugk_trainer/packed_alpha');
  static const _events = EventChannel('ugk_trainer/packed_alpha/events');
  late final _stream = _events
      .receiveBroadcastStream()
      .map((event) => Map<Object?, Object?>.from(event as Map))
      .asBroadcastStream();

  @override
  bool get isSupported =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      ui.ImageFilter.isShaderFilterSupported;

  @override
  Stream<Map<Object?, Object?>> get events => _stream;

  @override
  Future<({int playerId, int textureId})> create(String asset) async {
    final result = await _methods.invokeMapMethod<String, Object?>('create', {
      'asset': asset,
    });
    return (
      playerId: (result!['playerId'] as num).toInt(),
      textureId: (result['textureId'] as num).toInt(),
    );
  }

  @override
  Future<Object?> command(int playerId, String type, [Object? value]) =>
      _methods.invokeMethod<Object?>(type, {
        'playerId': playerId,
        'value': value,
      });
}
