// Live check against a real router: dart run tool/probe.dart <host> <username>   (password in env NM_PW)
// Makes exactly ONE login attempt.
import 'dart:io';

import 'package:netmeter/core/huawei_client.dart';

Future<void> main(List<String> args) async {
  final c = HuaweiClient(args[0], args[1], Platform.environment['NM_PW'] ?? '');
  try {
    final st = await c.loginState();
    stdout.writeln('state: locked=${st.locked} wait=${st.waitMinutes}');
    if (st.locked) return;
    await c.login();
    stdout.writeln('login ok');
    final hosts = await c.hosts();
    for (final h in hosts.where((h) => h.active)) {
      stdout.writeln('${h.name} ${h.ip} ${h.conn} local=${h.isLocal} rx=${h.rxBytes}');
    }
    final w = await c.wan();
    stdout.writeln('wan total rx=${w.totalRx} tx=${w.totalTx} rate=${w.downRate}/${w.upRate}');
  } on RouterError catch (e) {
    stdout.writeln('FAIL ${e.kind} ${e.code} ${e.message}');
  } finally {
    await c.logout();
    c.close();
  }
}
