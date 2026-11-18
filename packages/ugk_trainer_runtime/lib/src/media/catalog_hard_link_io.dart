import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final _createWindowsLink = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
      int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
    >('CreateHardLinkW');

final _createPosixLink = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)
    >('link');

/// Best-effort alias for the original relative media path. An unsupported
/// filesystem can still serve the path through an atomic local copy.
bool tryCatalogHardLink(File source, File alias) {
  try {
    return using((arena) {
      if (Platform.isWindows) {
        return _createWindowsLink(
              alias.absolute.path.toNativeUtf16(allocator: arena),
              source.absolute.path.toNativeUtf16(allocator: arena),
              nullptr,
            ) !=
            0;
      }
      return _createPosixLink(
            source.path.toNativeUtf8(allocator: arena),
            alias.path.toNativeUtf8(allocator: arena),
          ) ==
          0;
    });
  } on ArgumentError {
    return false;
  }
}
