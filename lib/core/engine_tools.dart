// Extra views of the recorded data: allowance and forecast, top devices, CSV export, the JSON the browser dashboard reads,
// and the made-up data of the demo mode.
import 'dart:io';

import 'engine.dart';
import 'huawei_client.dart';
import 'platform_utils.dart';
import 'store.dart';

extension EngineTools on Engine {
  /// Tells the user when the monthly allowance (if one is set) crosses 80, 90 and 100 percent.
  void checkQuota() {
    if (config.quotaGb <= 0) return;
    final p = sumWan(periodStart);
    final used = p.$1 + p.$2;
    final cap = config.quotaGb * 1024 * 1024 * 1024;
    final level = used >= cap ? 100 : (used >= cap * 0.9 ? 90 : (used >= cap * 0.8 ? 80 : 0));
    final period = dayKey(periodStart);
    final prev = (store.state['quotaLevel'] as String?)?.split(':');
    final prevLevel = prev != null && prev.first == period ? int.tryParse(prev.last) ?? 0 : 0;
    if (level > prevLevel) {
      store.state['quotaLevel'] = '$period:$level';
      notice = level >= 100 ? 'You used your whole ${config.quotaGb} GB allowance for this period.' : 'You used $level% of your ${config.quotaGb} GB allowance.';
    }
  }

  /// How much of the allowance is used and where the current pace leads by the end of the period.
  ({int used, int projected, int periodDays, int cap}) get quota {
    final p = sumWan(periodStart);
    final used = p.$1 + p.$2;
    final now = DateTime.now();
    final start = periodStart;
    final next = DateTime(start.year, start.month + 1, start.day);
    final periodDays = next.difference(start).inDays;
    final elapsed = (now.difference(start).inMinutes / 1440).clamp(0.25, periodDays.toDouble());
    return (used: used, projected: (used / elapsed * periodDays).round(), periodDays: periodDays, cap: config.quotaGb * 1024 * 1024 * 1024);
  }

  /// Router usage for each of the last [n] billing periods (calendar months when the period starts on day 1), oldest first.
  List<(DateTime, int)> lastMonths(int n) {
    final reset = config.resetDay;
    final cur = periodStart; // the period that contains today
    final out = <(DateTime, int)>[];
    for (var i = n - 1; i >= 0; i--) {
      // period i back from the current one: its start is the reset day of the month i before the current period's start
      final first = DateTime(cur.year, cur.month - i, 1);
      final last = DateTime(first.year, first.month + 1, 0).day;
      final start = DateTime(first.year, first.month, reset > last ? last : reset);
      final nextFirst = DateTime(cur.year, cur.month - i + 1, 1);
      final nextLast = DateTime(nextFirst.year, nextFirst.month + 1, 0).day;
      final end = DateTime(nextFirst.year, nextFirst.month, reset > nextLast ? nextLast : reset);
      var sum = 0;
      final a = dayKey(start), b = dayKey(end);
      store.days.forEach((k, v) {
        if (k.compareTo(a) >= 0 && k.compareTo(b) < 0) sum += v.wanRx + v.wanTx;
      });
      out.add((start, sum));
    }
    return out;
  }

  /// Router bytes for each hour of today.
  List<int> get hourlyToday => store.days[dayKey(DateTime.now())]?.hourly ?? List.filled(24, 0);

  /// Devices with the most connection time (or traffic, where the router reports it) in this period.
  List<(Device, int)> topDevices(int n) {
    final out = <(Device, int)>[];
    for (final d in store.devices.values) {
      final s = deviceStats(d.mac);
      final v = perDeviceUsage ? s.bytesPeriod : s.secsPeriod;
      if (v > 0) out.add((d, v));
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return out.take(n).toList();
  }

  /// Writes two CSV files (per day, and per device and day) to Documents\NetMeter and returns the folder.
  String exportCsv() {
    final sep = Platform.pathSeparator;
    final dir = Directory('${documentsDir()}${sep}NetMeter')..createSync(recursive: true);
    final keys = store.days.keys.toList()..sort();
    final daily = StringBuffer('date,router_down_bytes,router_up_bytes,pc_down_bytes,pc_up_bytes\n');
    final perDev = StringBuffer('date,mac,name,category,online_minutes,down_bytes,up_bytes\n');
    String q(String v) => '"${v.replaceAll('"', '""')}"';
    for (final k in keys) {
      final d = store.days[k]!;
      daily.writeln('$k,${d.wanRx},${d.wanTx},${d.pcRx},${d.pcTx}');
      d.dev.forEach((mac, v) {
        final dev = store.devices[mac];
        perDev.writeln('$k,$mac,${q(dev?.display ?? '')},${q(dev?.category ?? '')},${(v.secs / 60).round()},${v.rx},${v.tx}');
      });
    }
    File('${dir.path}${sep}netmeter-daily.csv').writeAsStringSync(daily.toString());
    File('${dir.path}${sep}netmeter-devices.csv').writeAsStringSync(perDev.toString());
    return dir.path;
  }

  /// Everything the browser dashboard shows.
  Map<String, dynamic> stateJson() {
    final todayWan = sumWan(today), periodWan = sumWan(periodStart);
    final pcToday = sumPc(today), pcPeriod = sumPc(periodStart);
    final q = quota;
    return {
      'version': version,
      'status': status,
      'error': error,
      'perDeviceUsage': perDeviceUsage,
      'periodStart': dayKey(periodStart),
      'rate': {'down': wan?.downRate ?? 0, 'up': wan?.upRate ?? 0},
      'today': {'down': todayWan.$1, 'up': todayWan.$2},
      'period': {'down': periodWan.$1, 'up': periodWan.$2},
      'pc': {'today': pcToday.$1 + pcToday.$2, 'period': pcPeriod.$1 + pcPeriod.$2},
      'quota': {'cap': q.cap, 'used': q.used, 'projected': q.projected, 'periodDays': q.periodDays},
      'hourly': hourlyToday,
      'days': [for (final d in lastDays(30)) {'date': dayKey(d.$1), 'bytes': d.$2}],
      'months': [for (final m in lastMonths(12)) {'start': dayKey(m.$1), 'bytes': m.$2}],
      'categories': categories,
      'devices': [
        for (final d in store.devices.values)
          () {
            final s = deviceStats(d.mac);
            return {
              'mac': d.mac,
              'name': d.name,
              'host': d.hostName,
              'display': d.display,
              'category': d.category,
              'conn': d.conn,
              'ip': d.ip,
              'online': d.online,
              'local': d.isLocal,
              'secsToday': s.secsToday,
              'secsPeriod': s.secsPeriod,
              'bytesToday': s.bytesToday,
              'bytesPeriod': s.bytesPeriod,
            };
          }(),
      ],
    };
  }

  /// Made-up devices and 45 days of history, for the screenshots in the README.
  void seedDemo() {
    if (store.devices.isNotEmpty) return;
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch ~/ 1000;
    final rows = [
      ('AA:BB:CC:00:00:01', 'Living room TV', 'TV', 'Wi-Fi', '192.168.1.20', true, false),
      ('AA:BB:CC:00:00:02', 'Work laptop', 'Computer', 'Wi-Fi', '192.168.1.21', true, true),
      ('AA:BB:CC:00:00:03', 'Anna phone', 'Phone', 'Wi-Fi', '192.168.1.22', true, false),
      ('AA:BB:CC:00:00:04', 'Tablet', 'Tablet', 'Wi-Fi', '192.168.1.23', false, false),
      ('AA:BB:CC:00:00:05', 'Game console', 'Console', 'Ethernet', '192.168.1.24', true, false),
      ('AA:BB:CC:00:00:06', 'Smart speaker', 'Smart home', 'Wi-Fi', '192.168.1.25', true, false),
      ('AA:BB:CC:00:00:07', 'Guest phone', 'Guest', 'Wi-Fi', '192.168.1.26', false, false),
    ];
    for (final r in rows) {
      store.devices[r.$1] = Device(r.$1)
        ..name = r.$2
        ..category = r.$3
        ..conn = r.$4
        ..ip = r.$5
        ..online = r.$6
        ..isLocal = r.$7
        ..firstSeen = ts - 40 * 86400
        ..lastSeen = ts;
    }
    var seed = 7;
    double next() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    const gb = 1024 * 1024 * 1024;
    for (var i = 0; i < 45; i++) {
      final t = DateTime(now.year, now.month, now.day).subtract(Duration(days: i));
      final d = store.day(t);
      final total = ((t.weekday >= 6 ? 9 : 5) * gb * (0.5 + next())).round();
      d.wanRx = (total * 0.88).round();
      d.wanTx = total - d.wanRx;
      d.pcRx = (total * 0.3).round();
      d.pcTx = (total * 0.03).round();
      final upTo = i == 0 ? now.hour + 1 : 24;
      for (var h = 0; h < upTo; h++) {
        final weight = h >= 18 && h <= 23 ? 3.0 : (h >= 8 ? 1.2 : 0.2);
        d.hourly[h] = (total / 40 * weight * (0.5 + next())).round();
      }
      for (final row in rows) {
        final dd = d.devDay(row.$1);
        dd.secs = ((row.$6 ? 40000 : 9000) * (0.4 + next())).round();
        if (row.$7) {
          dd.rx = d.pcRx;
          dd.tx = d.pcTx;
        }
      }
    }
    store.state['localMac'] = 'AA:BB:CC:00:00:02';
  }

  /// A demo router host list (for the live rates on the dashboard).
  List<HostRecord> demoHosts() => [
        for (final d in store.devices.values)
          HostRecord(mac: d.mac, ip: d.ip, name: d.name, conn: d.conn, active: d.online, rxBytes: 0, txBytes: 0, downRate: 0, upRate: 0, hasCounters: false, isLocal: d.isLocal),
      ];
}
