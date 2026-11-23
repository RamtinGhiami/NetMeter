// The few things that differ between Windows, Linux and macOS: where the data lives, how the router password is kept, how this
// PC's network counters are read, and how a URL is opened in the browser.
import 'dart:convert';
import 'dart:io';

import 'windows_api.dart';

String homeDir() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;

/// Folder for the settings and the history.
Directory appDataDir() {
  final override = Platform.environment['NETMETER_DATA']; // used by the demo mode and the tests
  if (override != null && override.isNotEmpty) return Directory(override)..createSync(recursive: true);
  final sep = Platform.pathSeparator;
  final String base;
  if (Platform.isWindows) {
    base = '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}${sep}NetMeter';
  } else if (Platform.isMacOS) {
    base = '${homeDir()}/Library/Application Support/NetMeter';
  } else {
    base = '${Platform.environment['XDG_CONFIG_HOME'] ?? '${homeDir()}/.config'}/NetMeter';
  }
  return Directory(base)..createSync(recursive: true);
}

String documentsDir() => '${homeDir()}${Platform.pathSeparator}Documents';

/// Windows keeps the router password encrypted with DPAPI (this Windows user only). Linux and macOS have no such call without
/// extra libraries, so there the password sits in the settings file, which is made readable by the current user only.
String? protectSecret(String text) => Platform.isWindows ? WindowsApi.protect(text) : 'plain:${base64.encode(utf8.encode(text))}';

String? unprotectSecret(String stored) {
  if (stored.startsWith('plain:')) return utf8.decode(base64.decode(stored.substring(6)));
  return Platform.isWindows ? WindowsApi.unprotect(stored) : null;
}

Future<void> restrictToOwner(File file) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('chmod', ['600', file.path]);
  } catch (_) {}
}

/// Windows counts the adapter bytes with 32 bits (they wrap at 4 GiB); Linux and macOS use 64 bits.
bool get counters32 => Platform.isWindows;

/// Bytes received and sent so far by this network interface, or null when they cannot be read.
Future<(int, int)?> adapterBytes(NetworkInterface nic) async {
  try {
    if (Platform.isWindows) return WindowsApi.adapterBytes(nic.index);
    if (Platform.isLinux) {
      for (final line in await File('/proc/net/dev').readAsLines()) {
        final t = line.trim();
        if (!t.startsWith('${nic.name}:')) continue;
        final f = t.substring(nic.name.length + 1).trim().split(RegExp(r'\s+'));
        return (int.parse(f[0]), int.parse(f[8]));
      }
    }
    if (Platform.isMacOS) {
      final r = await Process.run('netstat', ['-ib', '-I', nic.name]);
      for (final line in '${r.stdout}'.split('\n')) {
        final f = line.trim().split(RegExp(r'\s+'));
        if (f.length >= 10 && f.first == nic.name && f[2].startsWith('<Link')) {
          // ... Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
          return (int.parse(f[f.length - 5]), int.parse(f[f.length - 2]));
        }
      }
    }
  } catch (_) {}
  return null;
}

Future<void> openUrl(String url) async {
  if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [url]);
  } else {
    await Process.run('xdg-open', [url]);
  }
}

/// The tray icon file inside the installed app (an .ico on Windows, a PNG elsewhere).
String trayIconPath() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows) return [exeDir, 'data', 'flutter_assets', 'assets', 'tray_icon.ico'].join(sep);
  if (Platform.isMacOS) return '$exeDir/../Frameworks/App.framework/Resources/flutter_assets/assets/icon.png';
  return [exeDir, 'data', 'flutter_assets', 'assets', 'icon.png'].join(sep);
}
