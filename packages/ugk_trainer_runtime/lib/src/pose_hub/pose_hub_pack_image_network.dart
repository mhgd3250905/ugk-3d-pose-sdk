import 'package:flutter/widgets.dart';

Widget packImage(
  Uri uri, {
  required BoxFit fit,
  required String? semanticLabel,
  required ImageErrorWidgetBuilder errorBuilder,
  ImageFrameBuilder? frameBuilder,
  Key? key,
}) => Image.network(
  uri.toString(),
  key: key,
  fit: fit,
  semanticLabel: semanticLabel,
  errorBuilder: errorBuilder,
  frameBuilder: frameBuilder,
  gaplessPlayback: false,
);
