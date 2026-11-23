// Settings and recorded history, as two small JSON files in %APPDATA%\NetMeter. The router password is kept encrypted with
// Windows DPAPI (for this Windows user only), never as plain text.
import 'dart:convert';
import 'dart:io';

import 'windows_api.dart';

const categories = ['Phone', 'Computer', 'Tablet', 'TV', 'Console', 'Smart home', 'Guest', 'Other'];

String dayKey(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

Directory dataDir() {
  final override = Platform.environment['NETMETER_DATA']; // used by the demo mode and the tests
  if (override != null && override.isNotEmpty) return Directory(override)..createSync(recursive: true);
  final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
  return Directory('$base${Platform.pathSeparator}NetMeter')..createSync(recursive: true);
}

class Config {
  Config({this.host = '192.168.70.1', this.username = 'Admin', this.password = '', this.intervalSec = 20, this.resetDay = 1, this.autostart = true, this.quotaGb = 0});
  String host, username, password;
  int intervalSec, resetDay, quotaGb; // quotaGb 0 = no monthly allowance set
  bool autostart;

  static File get _file => File('${dataDir().path}${Platform.pathSeparator}config.json');

  static Config load() {
    final c = Config();
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      c.host = j['host'] ?? c.host;
      c.username = j['username'] ?? c.username;
      c.intervalSec = (j['intervalSec'] ?? c.intervalSec) as int;
      c.resetDay = (j['resetDay'] ?? c.resetDay) as int;
      c.autostart = j['autostart'] ?? c.autostart;
      c.quotaGb = (j['quotaGb'] ?? 0) as int;
      final enc = j['password'] as String?;
      if (enc != null && enc.isNotEmpty) c.password = WindowsApi.unprotect(enc) ?? '';
    } catch (_) {}
    return c;
  }

  void save() {
    final enc = password.isEmpty ? '' : (WindowsApi.protect(password) ?? '');
    _file.writeAsStringSync(jsonEncode({
      'host': host,
      'username': username,
      'password': enc,
      'intervalSec': intervalSec,
      'resetDay': resetDay,
      'autostart': autostart,
      'quotaGb': quotaGb,
    }));
  }
}

class Device {
  Device(this.mac)
      : ip = '',
        hostName = '',
        name = '',
        category = '',
        conn = '',
        firstSeen = 0,
        lastSeen = 0,
        online = false,
        isLocal = false;
  final String mac;
  String ip, hostName, name, category, conn;
  int firstSeen, lastSeen; // unix seconds
  bool online, isLocal;

  String get display => name.isNotEmpty ? name : (hostName.isNotEmpty ? hostName : mac);

  Map<String, dynamic> toJson() => {'ip': ip, 'host': hostName, 'name': name, 'cat': category, 'conn': conn, 'first': firstSeen, 'last': lastSeen, 'local': isLocal};

  static Device fromJson(String mac, Map<String, dynamic> j) => Device(mac)
    ..ip = j['ip'] ?? ''
    ..hostName = j['host'] ?? ''
    ..name = j['name'] ?? ''
    ..category = j['cat'] ?? ''
    ..conn = j['conn'] ?? ''
    ..firstSeen = j['first'] ?? 0
    ..lastSeen = j['last'] ?? 0
    ..isLocal = j['local'] ?? false;
}

class DevDay {
  int rx = 0, tx = 0, secs = 0;
  Map<String, dynamic> toJson() => {'rx': rx, 'tx': tx, 's': secs};
  static DevDay fromJson(Map<String, dynamic> j) => DevDay()
    ..rx = j['rx'] ?? 0
    ..tx = j['tx'] ?? 0
    ..secs = j['s'] ?? 0;
}

class DayStat {
  int wanRx = 0, wanTx = 0, pcRx = 0, pcTx = 0;
  /// Router bytes (down + up) per hour of the day, local time.
  List<int> hourly = List.filled(24, 0);
  final Map<String, DevDay> dev = {};
  DevDay devDay(String mac) => dev.putIfAbsent(mac, DevDay.new);
  Map<String, dynamic> toJson() => {'wr': wanRx, 'wt': wanTx, 'pr': pcRx, 'pt': pcTx, 'h': hourly, 'dev': dev.map((k, v) => MapEntry(k, v.toJson()))};
  static DayStat fromJson(Map<String, dynamic> j) {
    final d = DayStat()
      ..wanRx = j['wr'] ?? 0
      ..wanTx = j['wt'] ?? 0
      ..pcRx = j['pr'] ?? 0
      ..pcTx = j['pt'] ?? 0;
    final h = j['h'];
    if (h is List && h.length == 24) d.hourly = h.map((e) => (e as num).toInt()).toList();
    (j['dev'] as Map<String, dynamic>? ?? {}).forEach((k, v) => d.dev[k] = DevDay.fromJson(v as Map<String, dynamic>));
    return d;
  }
}

class Store {
  final Map<String, Device> devices = {};
  final Map<String, DayStat> days = {};
  /// Last counter values (router totals, this PC, per device), so a restart does not lose or double count anything.
  Map<String, dynamic> state = {};

  static File get _file => File('${dataDir().path}${Platform.pathSeparator}history.json');

  static Store load() {
    final s = Store();
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      (j['devices'] as Map<String, dynamic>? ?? {}).forEach((k, v) => s.devices[k] = Device.fromJson(k, v as Map<String, dynamic>));
      (j['days'] as Map<String, dynamic>? ?? {}).forEach((k, v) => s.days[k] = DayStat.fromJson(v as Map<String, dynamic>));
      s.state = (j['state'] as Map<String, dynamic>?) ?? {};
    } catch (_) {}
    return s;
  }

  void save() {
    final keep = days.keys.toList()..sort();
    while (keep.length > 400) {
      days.remove(keep.removeAt(0));
    }
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({
      'devices': devices.map((k, v) => MapEntry(k, v.toJson())),
      'days': days.map((k, v) => MapEntry(k, v.toJson())),
      'state': state,
    }));
    tmp.renameSync(_file.path);
  }

  DayStat day(DateTime t) => days.putIfAbsent(dayKey(t), DayStat.new);

  /// First day of the current billing period: [resetDay] of this month, or of last month when it has not come yet.
  static DateTime periodStart(DateTime now, int resetDay) {
    DateTime clamp(int y, int m) {
      final last = DateTime(y, m + 1, 0).day;
      return DateTime(y, m, resetDay > last ? last : resetDay);
    }

    final thisMonth = clamp(now.year, now.month);
    if (!now.isBefore(thisMonth)) return thisMonth;
    return now.month == 1 ? clamp(now.year - 1, 12) : clamp(now.year, now.month - 1);
  }
}
