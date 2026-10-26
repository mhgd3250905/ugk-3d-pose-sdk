import 'dart:io';

import 'package:flutter/widgets.dart';

Widget packImage(
  Uri uri, {
  required BoxFit fit,
  required String? semanticLabel,
  required ImageErrorWidgetBuilder errorBuilder,
}) => uri.scheme == 'file'
    ? Image.file(
        File.fromUri(uri),
        fit: fit,
        semanticLabel: semanticLabel,
        errorBuilder: errorBuilder,
        gaplessPlayback: false,
      )
    : Image.network(
        uri.toString(),
        fit: fit,
        semanticLabel: semanticLabel,
        errorBuilder: errorBuilder,
        gaplessPlayback: false,
      );
