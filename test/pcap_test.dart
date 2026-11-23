import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netmeter/core/pcap.dart';

Uint8List _frame(List<int> src, List<int> dst, int size) {
  final b = BytesBuilder();
  b.add(List.filled(12, 0)); // MACs
  b.add([0x08, 0x00]); // IPv4
  final ip = List<int>.filled(20, 0);
  ip[0] = 0x45;
  ip.setRange(12, 16, src);
  ip.setRange(16, 20, dst);
  b.add(ip);
  b.add(List.filled(size - 34, 0));
  return b.toBytes();
}

Uint8List _pcap(List<Uint8List> frames, {bool little = false}) {
  final e = little ? Endian.little : Endian.big;
  final b = BytesBuilder();
  final h = ByteData(24)
    ..setUint32(0, 0xa1b2c3d4, Endian.big)
    ..setUint16(4, 2, e)
    ..setUint16(6, 4, e)
    ..setUint32(16, 65535, e)
    ..setUint32(20, 1, e);
  if (little) h.setUint32(0, 0xd4c3b2a1, Endian.big);
  b.add(h.buffer.asUint8List());
  for (final f in frames) {
    final r = ByteData(16)
      ..setUint32(8, f.length, e)
      ..setUint32(12, f.length, e);
    b.add(r.buffer.asUint8List());
    b.add(f);
  }
  return b.toBytes();
}

void main() {
  const lan = (192 << 16) | (168 << 8) | 70;
  final phone = [192, 168, 70, 106], pc = [192, 168, 70, 109], web = [93, 184, 216, 34];

  test('counts download and upload per LAN address and ignores LAN to LAN', () {
    final c = PcapCounter(lanPrefix24: lan);
    c.add(_pcap([_frame(web, pc, 1500), _frame(web, pc, 1500), _frame(pc, web, 100), _frame(phone, pc, 700)]));
    expect(c.down[(192 << 24) | (168 << 16) | (70 << 8) | 109], 3000);
    expect(c.up[(192 << 24) | (168 << 16) | (70 << 8) | 109], 100);
    expect(c.down.length + c.up.length, 2); // the phone <-> PC frame is not counted
  });

  test('works when the stream arrives in small pieces, big or little endian', () {
    for (final little in [false, true]) {
      final bytes = _pcap([_frame(web, phone, 1400), _frame(phone, web, 90)], little: little);
      final c = PcapCounter(lanPrefix24: lan);
      for (var i = 0; i < bytes.length; i += 37) {
        c.add(bytes.sublist(i, i + 37 > bytes.length ? bytes.length : i + 37));
      }
      expect(c.down.values.single, 1400);
      expect(c.up.values.single, 90);
    }
  });
}
