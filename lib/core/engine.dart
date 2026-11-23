// The collector: polls the router, keeps the history and tells the UI what changed.
//
// Login safety: the router counts wrong passwords and then locks logins. After a failed login this engine never tries again
// on its own; it waits until the user changes the credentials (Settings) or presses "Try again".
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'engine_tools.dart';
import 'huawei_client.dart';
import 'store.dart';
import 'windows_api.dart';

const _maxStep = 50 * 1024 * 1024 * 1024; // a counter jump bigger than this between two polls is ignored
const _wrap32 = 4294967296;

class Engine extends ChangeNotifier {
  Engine({required this.version, required this.onAutostart, this.demo = false});
  final String version;

  /// Demo mode: made-up data and no router connection (used for the screenshots in the README).
  final bool demo;
  final Future<void> Function(bool on) onAutostart;

  late Config config;
  late Store store;
  HuaweiClient? _client;
  Timer? _timer;
  bool _polling = false;
  DateTime? _lastPoll;

  /// setup | connecting | connected | offline | blocked | error
  String status = 'setup';
  String? error;
  DateTime? lastOk;
  DateTime? blockedUntil;
  bool authBlocked = false;
  WanStat? wan;
  List<HostRecord> hosts = [];
  String? notice;
  int? _pcIndex;
  bool pcSupported = true;

  Future<void> start() async {
    config = Config.load();
    store = Store.load();
    if (demo) {
      seedDemo();
      config.quotaGb = 200; // shown in the screenshots; the demo never saves it
      hosts = demoHosts();
      status = 'connected';
      lastOk = DateTime.now();
      wan = WanStat(totalRx: 0, totalTx: 0, downRate: 2400000, upRate: 310000);
      notifyListeners();
      return;
    }
    await onAutostart(config.autostart);
    _restartTimer();
    unawaited(tick());
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: config.intervalSec.clamp(10, 300)), (_) => tick());
  }

  Future<void> shutdown() async {
    _timer?.cancel();
    store.save();
    await _client?.logout();
    _client?.close();
  }

  void log(String message) {
    try {
      File('${dataDir().path}${Platform.pathSeparator}netmeter.log').writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append);
    } catch (_) {}
  }

  // ---- settings ----------------------------------------------------------

  Future<void> applySettings({required String host, required String username, required String password, required int intervalSec, required int resetDay, required bool autostart, int quotaGb = 0}) async {
    final credentialsChanged = host != config.host || username != config.username || password != config.password;
    config
      ..host = host.trim()
      ..username = username.trim()
      ..password = password
      ..intervalSec = intervalSec
      ..resetDay = resetDay
      ..autostart = autostart
      ..quotaGb = quotaGb;
    config.save();
    await onAutostart(autostart);
    _restartTimer();
    if (credentialsChanged) {
      authBlocked = false;
      blockedUntil = null;
      _client?.close();
      _client = null;
    }
    notifyListeners();
    unawaited(tick());
  }

  /// One new login attempt after a failure (the user decided the credentials are right).
  Future<void> retryLogin() async {
    authBlocked = false;
    blockedUntil = null;
    _client?.close();
    _client = null;
    unawaited(tick());
  }

  void setDeviceMeta(String mac, {String? name, String? category}) {
    final d = store.devices[mac];
    if (d == null) return;
    if (name != null) d.name = name.trim();
    if (category != null) d.category = category;
    store.save();
    notifyListeners();
  }

  // ---- polling -----------------------------------------------------------

  Future<void> tick() async {
    if (demo || _polling) return;
    _polling = true;
    try {
      await _ensureAdapter();
      await _pollRouter();
    } catch (e) {
      log('tick error: $e');
    } finally {
      _polling = false;
      try {
        store.save();
      } catch (_) {}
      notifyListeners();
    }
  }

  /// This PC's own traffic, from the Windows adapter counters of the adapter that is on the router's network.
  Future<void> _ensureAdapter() async {
    if (!Platform.isWindows) return;
    try {
      _pcIndex ??= await _findAdapter();
    } catch (_) {}
  }

  Future<int?> _findAdapter() async {
    final prefix = config.host.split('.').take(3).join('.');
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (nic.addresses.any((a) => a.address.startsWith('$prefix.'))) return nic.index;
    }
    return null;
  }

  void _recordPc(DateTime now) {
    final idx = _pcIndex;
    if (idx == null) {
      pcSupported = false;
      return;
    }
    final b = WindowsApi.adapterBytes(idx);
    if (b == null) return;
    final last = (store.state['pc'] as List?)?.cast<int>();
    store.state['pc'] = [b.$1, b.$2];
    if (last == null) return;
    final rx = (b.$1 - last[0]) % _wrap32, tx = (b.$2 - last[1]) % _wrap32;
    if (rx > _maxStep || tx > _maxStep) return;
    final day = store.day(now);
    day.pcRx += rx;
    day.pcTx += tx;
    // the router gives no per-device counters, so the device that is this PC gets its own measured traffic
    final local = store.state['localMac'] as String?;
    if (local != null && store.state['counters'] != true) {
      day.devDay(local)
        ..rx += rx
        ..tx += tx;
    }
  }

  Future<void> _pollRouter() async {
    final now = DateTime.now();
    _recordPc(now);
    if (config.password.isEmpty) {
      status = 'setup';
      error = 'Enter the router password in Settings';
      return;
    }
    if (authBlocked) {
      status = 'blocked';
      return;
    }
    if (blockedUntil != null && now.isBefore(blockedUntil!)) {
      status = 'blocked';
      return;
    }
    blockedUntil = null;
    final client = _client ??= HuaweiClient(config.host, config.username, config.password);
    var stage = 'state';
    try {
      if (!client.loggedIn) {
        status = 'connecting';
        notifyListeners();
        final st = await client.loginState();
        if (st.locked) {
          throw RouterError('108007', 'The router locked logins for ${st.waitMinutes} min', 'locked');
        }
        stage = 'login';
        await client.login();
      }
      stage = 'hosts';
      final h = await client.hosts();
      stage = 'wan';
      final w = await client.wan();
      hosts = h;
      wan = w;
      _record(now, h, w);
      status = 'connected';
      error = null;
      lastOk = now;
    } on RouterError catch (e) {
      error = e.message;
      log('router error at $stage (${e.kind}/${e.code}): ${e.message}');
      switch (e.kind) {
        case 'auth':
          authBlocked = true;
          status = 'blocked';
          error = '${e.message}. Not retrying, to avoid locking the router. Check Settings.';
          _client = null;
        case 'locked':
          blockedUntil = now.add(const Duration(minutes: 5));
          status = 'blocked';
          _client = null;
        case 'busy':
          blockedUntil = now.add(const Duration(minutes: 1));
          status = 'blocked';
          _client = null;
        case 'network':
          status = 'offline';
        default:
          status = 'error';
          _client?.close();
          _client = null;
      }
    }
  }

  void _record(DateTime now, List<HostRecord> list, WanStat w) {
    final day = store.day(now);
    final dt = _lastPoll == null ? 0 : now.difference(_lastPoll!).inSeconds.clamp(0, 120);
    _lastPoll = now;
    final ts = now.millisecondsSinceEpoch ~/ 1000;

    // router total
    final lastWan = (store.state['wan'] as List?)?.cast<int>();
    if (lastWan != null) {
      var rx = w.totalRx - lastWan[0], tx = w.totalTx - lastWan[1];
      if (rx < 0) rx = w.totalRx; // the router's counters were cleared
      if (tx < 0) tx = w.totalTx;
      if (rx < _maxStep && tx < _maxStep) {
        day.wanRx += rx;
        day.wanTx += tx;
        day.hourly[now.hour] += rx + tx;
      }
    }
    store.state['wan'] = [w.totalRx, w.totalTx];

    final perDev = (store.state['dev'] as Map<String, dynamic>?) ?? {};
    final seen = <String>{};
    for (final h in list) {
      seen.add(h.mac);
      final isNew = !store.devices.containsKey(h.mac);
      final d = store.devices.putIfAbsent(h.mac, () => Device(h.mac)..firstSeen = ts);
      if (isNew && store.state['seeded'] == true) notice = 'New device on your network: ${h.name.isEmpty ? h.mac : h.name} (${h.ip})';
      d
        ..ip = h.ip.isNotEmpty ? h.ip : d.ip
        ..hostName = h.name.isNotEmpty ? h.name : d.hostName
        ..conn = h.conn.isNotEmpty ? h.conn : d.conn
        ..online = h.active
        ..isLocal = h.isLocal || d.isLocal;
      if (h.isLocal) store.state['localMac'] = h.mac;
      if (h.active) {
        d.lastSeen = ts;
        day.devDay(h.mac).secs += dt;
      }
      // per-device counters: only some routers fill them in; this one reports zeros
      if (h.hasCounters && (h.rxBytes > 0 || h.txBytes > 0)) store.state['counters'] = true;
      if (store.state['counters'] == true) {
        final last = (perDev[h.mac] as List?)?.cast<int>();
        if (last != null) {
          var rx = h.rxBytes - last[0], tx = h.txBytes - last[1];
          if (rx < 0) rx = h.rxBytes;
          if (tx < 0) tx = h.txBytes;
          if (rx < _maxStep && tx < _maxStep) {
            day.devDay(h.mac)
              ..rx += rx
              ..tx += tx;
          }
        }
        perDev[h.mac] = [h.rxBytes, h.txBytes];
      }
    }
    store.state['dev'] = perDev;
    store.state['seeded'] = true; // from now on a device the router has not shown before is reported as new
    checkQuota();
    for (final d in store.devices.values) {
      if (!seen.contains(d.mac)) d.online = false;
    }
  }

  // ---- numbers for the UI ------------------------------------------------

  bool get perDeviceUsage => store.state['counters'] == true;

  /// Sum over the days from [from] (inclusive) to today.
  (int, int) sumWan(DateTime from) => _sum(from, (d) => (d.wanRx, d.wanTx));
  (int, int) sumPc(DateTime from) => _sum(from, (d) => (d.pcRx, d.pcTx));

  (int, int) _sum(DateTime from, (int, int) Function(DayStat) pick) {
    var rx = 0, tx = 0;
    final start = dayKey(from);
    store.days.forEach((k, v) {
      if (k.compareTo(start) >= 0) {
        final p = pick(v);
        rx += p.$1;
        tx += p.$2;
      }
    });
    return (rx, tx);
  }

  DateTime get today => DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  DateTime get periodStart => Store.periodStart(today, config.resetDay);

  /// Router usage for the last [n] days, oldest first.
  List<(DateTime, int)> lastDays(int n) {
    final out = <(DateTime, int)>[];
    for (var i = n - 1; i >= 0; i--) {
      final t = today.subtract(Duration(days: i));
      final d = store.days[dayKey(t)];
      out.add((t, d == null ? 0 : d.wanRx + d.wanTx));
    }
    return out;
  }

  /// A device's numbers for the current period and for today.
  ({int secsToday, int secsPeriod, int bytesToday, int bytesPeriod}) deviceStats(String mac) {
    var secsPeriod = 0, bytesPeriod = 0;
    final start = dayKey(periodStart);
    store.days.forEach((k, v) {
      if (k.compareTo(start) >= 0) {
        final dd = v.dev[mac];
        if (dd != null) {
          secsPeriod += dd.secs;
          bytesPeriod += dd.rx + dd.tx;
        }
      }
    });
    final t = store.days[dayKey(DateTime.now())]?.dev[mac];
    return (secsToday: t?.secs ?? 0, secsPeriod: secsPeriod, bytesToday: (t?.rx ?? 0) + (t?.tx ?? 0), bytesPeriod: bytesPeriod);
  }
}

String formatBytes(num b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble(), i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 10 ? 1 : 2)} ${units[i]}';
}

String formatRate(num bytesPerSec) => '${formatBytes(bytesPerSec)}/s';

String formatSpan(int secs) {
  if (secs < 60) return '${secs}s';
  final m = secs ~/ 60;
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${m % 60}m';
}
