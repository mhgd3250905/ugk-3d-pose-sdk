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

/// Optional capability: legacy implementations retain the asset-only interface.
abstract interface class PackedAlphaUriPlatform {
  Future<({int playerId, int textureId})> createUri(Uri sourceUri);
}

class MethodChannelPackedAlphaPlatform
    implements PackedAlphaPlatform, PackedAlphaUriPlatform {
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
  Future<({int playerId, int textureId})> createUri(Uri sourceUri) async {
    validatePackedAlphaSourceUri(sourceUri);
    final result = await _methods.invokeMapMethod<String, Object?>('create', {
      'sourceUri': sourceUri.toString(),
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

/// Caller-selected pack URIs only; never accept credentials or ambiguous paths.
void validatePackedAlphaSourceUri(Uri sourceUri) {
  final file = sourceUri.scheme == 'file';
  if (!sourceUri.isAbsolute ||
      !const ['file', 'http', 'https'].contains(sourceUri.scheme) ||
      sourceUri.userInfo.isNotEmpty ||
      sourceUri.hasQuery ||
      sourceUri.hasFragment ||
      !sourceUri.path.startsWith('/') ||
      sourceUri.pathSegments.any((p) => p == '.' || p == '..') ||
      !sourceUri.path.toLowerCase().endsWith('.mp4') ||
      (file ? sourceUri.host.isNotEmpty : sourceUri.host.isEmpty)) {
    throw const FormatException('Expected a trusted absolute packed MP4 URI');
  }
}
