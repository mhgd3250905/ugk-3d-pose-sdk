import 'package:flutter/widgets.dart';

Widget packImage(
  Uri uri, {
  required BoxFit fit,
  required String? semanticLabel,
  required ImageErrorWidgetBuilder errorBuilder,
}) => Image.network(
  uri.toString(),
  fit: fit,
  semanticLabel: semanticLabel,
  errorBuilder: errorBuilder,
  gaplessPlayback: false,
);
