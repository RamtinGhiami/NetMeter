// Small pieces of the Windows API used by the app: DPAPI (the router password is stored encrypted for this Windows user) and
// the network adapter byte counters of this PC (GetIfTable).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _ProtectNative = Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _ProtectDart = int Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _UnprotectNative = Int32 Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _UnprotectDart = int Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _FreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _FreeDart = Pointer<Void> Function(Pointer<Void>);

class WindowsApi {
  /// Encrypts [text] for the signed-in Windows user. Returns base64, or null when DPAPI is not available (not Windows).
  static String? protect(String text) {
    if (!Platform.isWindows) return null;
    final crypt = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final protect = crypt.lookupFunction<_ProtectNative, _ProtectDart>('CryptProtectData');
    final free = kernel.lookupFunction<_FreeNative, _FreeDart>('LocalFree');
    final bytes = utf8.encode(text);
    final input = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      input.ref.cbData = bytes.length;
      input.ref.pbData = buffer;
      final ok = protect(input, nullptr, nullptr, nullptr, nullptr, 0, output);
      if (ok == 0) return null;
      final result = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      free(output.ref.pbData.cast());
      return base64.encode(result);
    } finally {
      calloc.free(buffer);
      calloc.free(input);
      calloc.free(output);
    }
  }

  /// The reverse of [protect]; null when the data cannot be decrypted (another user or another machine).
  static String? unprotect(String encoded) {
    if (!Platform.isWindows) return null;
    final crypt = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final unprotect = crypt.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData');
    final free = kernel.lookupFunction<_FreeNative, _FreeDart>('LocalFree');
    final bytes = base64.decode(encoded);
    final input = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      input.ref.cbData = bytes.length;
      input.ref.pbData = buffer;
      final ok = unprotect(input, nullptr, nullptr, nullptr, nullptr, 0, output);
      if (ok == 0) return null;
      final text = utf8.decode(output.ref.pbData.asTypedList(output.ref.cbData));
      free(output.ref.pbData.cast());
      return text;
    } finally {
      calloc.free(buffer);
      calloc.free(input);
      calloc.free(output);
    }
  }

  /// Bytes received and sent so far by the adapter with this Windows interface index (32-bit counters: they wrap at 4 GiB).
  static (int, int)? adapterBytes(int index) {
    if (!Platform.isWindows) return null;
    final ip = DynamicLibrary.open('iphlpapi.dll');
    final getTable = ip.lookupFunction<Int32 Function(Pointer<Uint8>, Pointer<Uint32>, Int32), int Function(Pointer<Uint8>, Pointer<Uint32>, int)>('GetIfTable');
    final size = calloc<Uint32>();
    size.value = 1 << 17;
    final buf = calloc<Uint8>(size.value);
    try {
      if (getTable(buf, size, 0) != 0) return null;
      final view = buf.asTypedList(size.value);
      final data = ByteData.sublistView(view);
      final n = data.getUint32(0, Endian.little);
      // MIB_IFROW is 860 bytes: dwIndex at 512, dwInOctets at 552, dwOutOctets at 576
      for (var i = 0; i < n; i++) {
        final o = 4 + i * 860;
        if (data.getUint32(o + 512, Endian.little) == index) {
          return (data.getUint32(o + 552, Endian.little), data.getUint32(o + 576, Endian.little));
        }
      }
      return null;
    } finally {
      calloc.free(buf);
      calloc.free(size);
    }
  }
}
