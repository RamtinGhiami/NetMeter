// Writes %APPDATA%\NetMeter\config.json for a headless test: dart run tool/setup_config.dart <host> <username>  (password in env NM_PW)
import 'dart:io';

import 'package:netmeter/core/store.dart';

void main(List<String> args) {
  Config(host: args[0], username: args[1], password: Platform.environment['NM_PW'] ?? '').save();
  stdout.writeln('saved');
}
