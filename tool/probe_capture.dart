// Live check of the per-device estimate: logs in once, runs one 20 s packet capture and prints the bytes per LAN address.
// dart run tool/probe_capture.dart <host> <username>   (password in env NM_PW)
import 'dart:io';

import 'package:netmeter/core/huawei_client.dart';
import 'package:netmeter/core/pcap.dart';

Future<void> main(List<String> args) async {
  final c = HuaweiClient(args[0], args[1], Platform.environment['NM_PW'] ?? '');
  final p = args[0].split('.').map(int.parse).toList();
  final counter = PcapCounter(lanPrefix24: (p[0] << 16) | (p[1] << 8) | p[2]);
  try {
    await c.login();
    stdout.writeln('login ok, capturing 20 s...');
    final sw = Stopwatch()..start();
    await c.capture(const Duration(seconds: 20), counter.add, abort: () => counter.full);
    stdout.writeln('done in ${sw.elapsed.inSeconds}s, ${counter.total ~/ 1024} KB, ${counter.packets} packets');
    final ips = {...counter.down.keys, ...counter.up.keys}.toList()..sort();
    for (final ip in ips) {
      stdout.writeln('${PcapCounter.ipString(ip)}  down ${((counter.down[ip] ?? 0) / 1e6).toStringAsFixed(1)} MB  up ${((counter.up[ip] ?? 0) / 1e6).toStringAsFixed(1)} MB');
    }
  } on RouterError catch (e) {
    stdout.writeln('FAIL ${e.kind} ${e.code} ${e.message}');
  } finally {
    await c.stopCapture();
    await c.logout();
    c.close();
  }
}
