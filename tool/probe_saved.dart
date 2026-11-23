// Like probe.dart but with the saved config (checks the DPAPI password round trip): dart run tool/probe_saved.dart
import 'dart:io';

import 'package:netmeter/core/huawei_client.dart';
import 'package:netmeter/core/store.dart';

Future<void> main() async {
  final cfg = Config.load();
  stdout.writeln('host="${cfg.host}" user="${cfg.username}" passLen=${cfg.password.length}');
  final c = HuaweiClient(cfg.host, cfg.username, cfg.password);
  try {
    final st = await c.loginState();
    stdout.writeln('locked=${st.locked}');
    await c.login();
    stdout.writeln('login ok');
  } on RouterError catch (e) {
    stdout.writeln('FAIL ${e.kind} ${e.code} ${e.message}');
  } finally {
    await c.logout();
    c.close();
  }
}
