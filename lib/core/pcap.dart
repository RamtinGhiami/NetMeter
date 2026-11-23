// Reads a classic pcap stream (what the router's packet capture returns) while it arrives and adds up, per LAN address, how many
// bytes went to and from the internet. Only addresses and frame sizes are looked at; the packet contents are never kept.
import 'dart:typed_data';

class PcapCounter {
  PcapCounter({required this.lanPrefix24, this.maxBytes = 600 * 1024 * 1024});

  /// The first three bytes of the LAN, as a number: 192.168.70.x is (192 << 16) | (168 << 8) | 70.
  final int lanPrefix24;

  /// The capture is cut off after this many bytes, so a busy network cannot make one sample huge.
  final int maxBytes;

  /// Bytes from the internet to a LAN address (download) and from it to the internet (upload), keyed by IPv4 address.
  final Map<int, int> down = {}, up = {};
  int total = 0, packets = 0;
  bool _header = false, _little = false;
  Uint8List _carry = Uint8List(0);

  bool get full => total >= maxBytes;

  static String ipString(int ip) => '${(ip >> 24) & 255}.${(ip >> 16) & 255}.${(ip >> 8) & 255}.${ip & 255}';

  void add(List<int> chunk) {
    total += chunk.length;
    var data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    if (_carry.isNotEmpty) {
      final joined = Uint8List(_carry.length + data.length)
        ..setAll(0, _carry)
        ..setAll(_carry.length, data);
      data = joined;
    }
    final view = ByteData.sublistView(data);
    var pos = 0;
    if (!_header) {
      if (data.length < 24) {
        _carry = Uint8List.fromList(data);
        return;
      }
      final magic = view.getUint32(0, Endian.big);
      if (magic == 0xa1b2c3d4 || magic == 0xa1b23c4d) {
        _little = false;
      } else if (magic == 0xd4c3b2a1 || magic == 0x4d3cb2a1) {
        _little = true;
      } else {
        throw const FormatException('not a pcap stream');
      }
      final link = view.getUint32(20, _little ? Endian.little : Endian.big);
      if (link != 1) throw FormatException('unsupported link type $link');
      _header = true;
      pos = 24;
    }
    final e = _little ? Endian.little : Endian.big;
    while (data.length - pos >= 16) {
      final incl = view.getUint32(pos + 8, e);
      final orig = view.getUint32(pos + 12, e);
      if (incl > 262144) throw const FormatException('bad pcap record');
      if (data.length - pos - 16 < incl) break;
      _packet(view, pos + 16, incl, orig);
      pos += 16 + incl;
    }
    _carry = pos >= data.length ? Uint8List(0) : Uint8List.fromList(Uint8List.sublistView(data, pos));
  }

  void _packet(ByteData v, int o, int len, int origLen) {
    if (len < 34) return;
    var type = v.getUint16(o + 12, Endian.big);
    var ip = o + 14;
    if (type == 0x8100) {
      if (len < 38) return;
      type = v.getUint16(o + 16, Endian.big);
      ip = o + 18;
    }
    if (type != 0x0800) return;
    final src = v.getUint32(ip + 12, Endian.big), dst = v.getUint32(ip + 16, Endian.big);
    final srcLan = (src >> 8) == lanPrefix24, dstLan = (dst >> 8) == lanPrefix24;
    packets++;
    if (srcLan && !dstLan) {
      up[src] = (up[src] ?? 0) + origLen;
    } else if (dstLan && !srcLan) {
      down[dst] = (down[dst] ?? 0) + origLen;
    }
  }
}
