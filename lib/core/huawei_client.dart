// Client for the web API of Huawei 5G CPE routers (tested on the H155-383 "5G CPE 5").
//
// The login is the Huawei SCRAM flow. It is a port of the logic in CPE-Monitor
// (https://github.com/, GPL-2.0-or-later) and was checked against the router's own CryptoJS code
// (see test/scram_test.dart). Huawei's HMAC argument order is NOT standard SCRAM: the label or the
// auth message is the HMAC key.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// kind: network | auth | locked | busy | session | forbidden | error
class RouterError implements Exception {
  RouterError(this.code, this.message, this.kind);
  final String code;
  final String message;
  final String kind;
  @override
  String toString() => message;
}

String classify(String code) {
  if (const {'108001', '108002', '108006'}.contains(code)) return 'auth';
  if (const {'108007', '108010'}.contains(code)) return 'locked';
  if (const {'108003', '108005', '108009'}.contains(code)) return 'busy';
  if (const {'100002', '125001', '125002', '125003'}.contains(code)) return 'session';
  if (code == '100003') return 'forbidden';
  return 'error';
}

String describe(String code) => switch (classify(code)) {
      'auth' => 'Wrong username or password',
      'locked' => 'Too many login attempts; the router locked logins for a few minutes',
      'busy' => 'Another session is open on the router; sign out of its web panel',
      'session' => 'The router session expired',
      'forbidden' => 'This account may not use that feature',
      _ => 'Router error ($code)',
    };

// ---- SCRAM primitives (public so the unit test can check them against the router's JS) ----

List<int> hmacSha256(List<int> key, List<int> message) => Hmac(sha256, key).convert(message).bytes;

/// PBKDF2-HMAC-SHA256, one 32-byte block.
Uint8List pbkdf2Sha256(String password, List<int> salt, int rounds) {
  final mac = Hmac(sha256, utf8.encode(password));
  var u = mac.convert([...salt, 0, 0, 0, 1]).bytes;
  final t = Uint8List.fromList(u);
  for (var i = 1; i < rounds; i++) {
    u = mac.convert(u).bytes;
    for (var j = 0; j < 32; j++) {
      t[j] ^= u[j];
    }
  }
  return t;
}

List<int> hexDecode(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
String hexEncode(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The client proof and the expected server signature for one login.
({String proof, String serverSignature, Uint8List salted}) scram(String password, String saltHex, int rounds, String authMessage) {
  final salted = pbkdf2Sha256(password, hexDecode(saltHex), rounds);
  final clientKey = hmacSha256(utf8.encode('Client Key'), salted);
  final storedKey = sha256.convert(clientKey).bytes;
  final signature = hmacSha256(utf8.encode(authMessage), storedKey);
  final proof = [for (var i = 0; i < 32; i++) clientKey[i] ^ signature[i]];
  final serverKey = hmacSha256(utf8.encode('Server Key'), salted);
  final serverSignature = hmacSha256(utf8.encode(authMessage), serverKey);
  return (proof: hexEncode(proof), serverSignature: hexEncode(serverSignature), salted: salted);
}

/// One device from the router's host table.
class HostRecord {
  HostRecord({
    required this.mac,
    required this.ip,
    required this.name,
    required this.conn,
    required this.active,
    required this.rxBytes,
    required this.txBytes,
    required this.downRate,
    required this.upRate,
    required this.hasCounters,
    required this.isLocal,
  });
  final String mac, ip, name, conn;
  final bool active, hasCounters, isLocal;
  final int rxBytes, txBytes, downRate, upRate;
}

class WanStat {
  WanStat({required this.totalRx, required this.totalTx, required this.downRate, required this.upRate});
  final int totalRx, totalTx, downRate, upRate;
}

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}'.trim()) ?? 0;

class HuaweiClient {
  HuaweiClient(this.host, this.username, this.password) {
    _http = HttpClient()
      ..findProxy = ((_) => 'DIRECT') // the LAN must never go through a system proxy or VPN
      ..badCertificateCallback = ((cert, h, port) => h == host) // the router's self-signed cert, this host only
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'NetMeter/0.2';
  }

  final String host, username, password;
  late final HttpClient _http;
  final _cookies = <String, String>{};
  final _tokens = <String>[];
  bool loggedIn = false;
  String get _base => 'https://$host';

  void close() => _http.close(force: true);

  Future<(int, Map<String, String>, String)> _send(String method, String path, {String? body, String? contentType, Map<String, String>? extra}) async {
    try {
      final req = await _http.openUrl(method, Uri.parse('$_base$path'));
      req.followRedirects = true;
      req.headers
        ..set('Accept', 'application/json, text/javascript, */*; q=0.01')
        ..set('Referer', '$_base/')
        ..set('Origin', _base)
        ..set('X-Requested-With', 'XMLHttpRequest')
        ..set('_ResponseSource', 'Broswer');
      extra?.forEach(req.headers.set);
      if (_tokens.isNotEmpty) req.headers.set('__RequestVerificationToken', _tokens.first);
      if (_cookies.isNotEmpty) req.headers.set('Cookie', _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
      if (body != null) {
        req.headers.set('Content-Type', contentType ?? 'application/x-www-form-urlencoded; charset=UTF-8');
        req.add(utf8.encode(body));
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join();
      // parsed by hand: the router sends a Set-Cookie that dart:io's own cookie parser rejects
      for (final line in res.headers['set-cookie'] ?? const <String>[]) {
        final pair = line.split(';').first;
        final eq = pair.indexOf('=');
        if (eq > 0) _cookies[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
      }
      String? h(String n) => res.headers.value(n);
      final one = h('__requestverificationtokenone'), two = h('__requestverificationtokentwo'), single = h('__requestverificationtoken');
      if (one != null || single != null) {
        _tokens.clear();
        if (one != null) _tokens.add(one);
        if (two != null) {
          _tokens.add(two);
        } else if (single != null && one == null) {
          _tokens.add(single);
        }
      } else if (method == 'POST' && _tokens.length > 1) {
        _tokens.add(_tokens.removeAt(0));
      }
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k] = v.join(','));
      return (res.statusCode, headers, text);
    } on RouterError {
      rethrow;
    } catch (e) {
      throw RouterError('network', 'Cannot reach the router at $host (${e.runtimeType}: $e)', 'network');
    }
  }

  static String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// Flat XML (a response element holding simple child elements) to a map; an error element throws.
  Object _parse(String body) {
    final text = body.trim();
    if (text.isEmpty) return <String, dynamic>{};
    if (text.startsWith('{') || text.startsWith('[')) {
      final data = jsonDecode(text);
      if (data is Map && data.containsKey('code') && data.length <= 4) {
        final code = '${data['code']}';
        throw RouterError(code, describe(code), classify(code));
      }
      return data as Object;
    }
    if (text.contains('<error>')) {
      String? tag(String n) => RegExp('<$n>([^<]*)</$n>').firstMatch(text)?.group(1);
      final code = tag('code') ?? 'unknown';
      var message = describe(code);
      final wait = tag('waittime') ?? tag('tobelockedtime');
      final remain = tag('remaincount');
      if (classify(code) == 'locked' && wait != null && wait.isNotEmpty) {
        message += ' ($wait min)';
      } else if (remain != null && remain.isNotEmpty) {
        message += ' ($remain attempts left)';
      }
      throw RouterError(code, message, classify(code));
    }
    final out = <String, dynamic>{};
    for (final m in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(text)) {
      out[m.group(1)!] = m.group(2)!;
    }
    return out;
  }

  Future<Object> get(String path) async {
    final (status, _, body) = await _send('GET', '/api/$path');
    if (status >= 400) throw RouterError('http$status', 'The router answered HTTP $status', 'network');
    return _parse(body);
  }

  Future<Object> post(String path, Map<String, Object> fields) async {
    final xml = '<?xml version="1.0" encoding="UTF-8"?><request>${fields.entries.map((e) => '<${e.key}>${_esc('${e.value}')}</${e.key}>').join()}</request>';
    final (status, _, body) = await _send('POST', '/api/$path', body: xml);
    if (status >= 400) throw RouterError('http$status', 'The router answered HTTP $status', 'network');
    return _parse(body);
  }

  /// Turns the router's packet capture on or off (a developer feature of the web panel).
  Future<void> setCapture(bool on) async {
    final body = jsonEncode({
      'data': {'Enable': on, 'EffectTime': 15, 'Port': 'ethwan_lan_wifi', 'OtherEffectTime': 15},
    });
    final (status, _, text) = await _send('POST', '/api/ntwk/ipcapture', body: body, contentType: 'application/json;charset=UTF-8', extra: {'_ResponseFormat': 'JSON'});
    if (status >= 400) throw RouterError('http$status', 'The router answered HTTP $status', 'network');
    final r = _parse(text);
    if (r is Map && r['errcode'] != null && '${r['errcode']}' != '0') {
      throw RouterError('${r['errcode']}', 'The router refused the packet capture (${r['errcode']})', 'error');
    }
  }

  /// Runs one packet capture of about [window] and hands the pcap bytes to [onData] as they arrive. The router stops the capture
  /// when it is switched off, which also ends the download. [abort] can end it early. The capture is always switched off again.
  Future<void> capture(Duration window, void Function(List<int>) onData, {bool Function()? abort}) async {
    await setCapture(true);
    var stopped = false;
    Future<void> stop() async {
      if (stopped) return;
      stopped = true;
      try {
        await setCapture(false);
      } catch (_) {}
    }

    try {
      final req = await _http.openUrl('GET', Uri.parse('$_base/api/ntwk/ipcapturestart'));
      req.headers
        ..set('Referer', '$_base/')
        ..set('Origin', _base)
        ..set('X-Requested-With', 'XMLHttpRequest')
        ..set('_ResponseSource', 'Broswer');
      if (_tokens.isNotEmpty) req.headers.set('__RequestVerificationToken', _tokens.first);
      if (_cookies.isNotEmpty) req.headers.set('Cookie', _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
      final res = await req.close();
      if (res.statusCode != 200) throw RouterError('http${res.statusCode}', 'The capture download failed (HTTP ${res.statusCode})', 'network');
      final done = Completer<void>();
      final sub = res.listen(
        (c) {
          onData(c);
          if (abort?.call() == true) unawaited(stop());
        },
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object e) => done.isCompleted ? null : done.completeError(e),
        cancelOnError: true,
      );
      final timer = Timer(window, () => unawaited(stop()));
      try {
        await done.future.timeout(window + const Duration(seconds: 25));
      } finally {
        timer.cancel();
        await sub.cancel();
      }
    } on RouterError {
      rethrow;
    } catch (e) {
      if (e is FormatException) rethrow;
      throw RouterError('network', 'The packet capture failed (${e.runtimeType})', 'network');
    } finally {
      await stop();
    }
  }

  Future<void> stopCapture() async {
    try {
      await setCapture(false);
    } catch (_) {}
  }

  Map<String, dynamic> _map(Object o) => o is Map<String, dynamic> ? o : <String, dynamic>{};

  Future<void> _initialize() async {
    _tokens.clear();
    final (_, _, html) = await _send('GET', '/');
    for (final m in RegExp(r'name="csrf_token"\s+content="([^"]+)"').allMatches(html)) {
      _tokens.add(m.group(1)!);
    }
    if (_tokens.isEmpty) {
      for (final m in RegExp(r'content="([^"]+)"\s+name="csrf_token"').allMatches(html)) {
        _tokens.add(m.group(1)!);
      }
    }
  }

  /// The login state as the router reports it, without trying to log in (no attempt is spent).
  Future<({bool locked, int waitMinutes, bool loggedIn})> loginState() async {
    await _initialize();
    final s = _map(await get('user/state-login'));
    return (locked: _int(s['lockstatus']) != 0, waitMinutes: _int(s['remainwaittime']), loggedIn: '${s['State']}' == '0');
  }

  /// Exactly one login attempt. The caller must never retry on an `auth` error: the router counts failures and locks.
  Future<void> login() async {
    if (password.isEmpty) throw RouterError('nopass', 'No router password is set', 'auth');
    _cookies.clear(); // the router allows one session; a stale half-finished one makes it answer 100006
    await _initialize();
    final nonce = hexEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    final ch = _map(await post('user/challenge_login', {'username': username, 'firstnonce': nonce, 'mode': 1}));
    final serverNonce = '${ch['servernonce'] ?? ''}';
    if (serverNonce.length <= nonce.length || !serverNonce.startsWith(nonce)) {
      throw RouterError('challenge', 'The router login challenge did not verify', 'auth');
    }
    final salt = '${ch['salt'] ?? ''}';
    final rounds = _int(ch['iterations']);
    if (salt.isEmpty || rounds < 1 || rounds > 2000000) throw RouterError('challenge', 'The router login parameters are invalid', 'auth');

    final auth = '$nonce,$serverNonce,$serverNonce';
    final r = scram(password, salt, rounds, auth);
    final body = <String, Object>{'clientproof': r.proof, 'finalnonce': serverNonce};
    if ('${ch['newType']}' == '1') {
      final newSalt = '${ch['newSalt'] ?? ''}';
      final newRounds = _int(ch['newIterations']);
      if (newSalt.isNotEmpty && newRounds > 0) {
        final s2 = pbkdf2Sha256(password, hexDecode(newSalt), newRounds);
        final stored = hexEncode(sha256.convert(hmacSha256(utf8.encode('Client Key'), s2)).bytes);
        final server = hexEncode(hmacSha256(utf8.encode('Server Key'), s2));
        body['hashOldNewPwd'] = sha256.convert(utf8.encode('$stored$server${r.proof}')).toString();
        body['newStoredKey'] = stored;
        body['newServerKey'] = server;
      }
    }
    final res = _map(await post('user/authentication_login', body));
    final sig = '${res['serversignature'] ?? ''}'.toLowerCase();
    if (sig.isNotEmpty && sig != r.serverSignature) {
      throw RouterError('signature', 'The router signature did not verify', 'auth');
    }
    loggedIn = true;
  }

  Future<T> _relogin<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on RouterError catch (e) {
      if (e.kind != 'session') rethrow;
      loggedIn = false;
      await login();
      return fn();
    }
  }

  Future<void> logout() async {
    try {
      await post('user/logout', {'Logout': 1});
    } catch (_) {}
    loggedIn = false;
  }

  Future<List<HostRecord>> hosts() => _relogin(() async {
        final data = await get('system/HostInfo');
        final list = data is List ? data : (data is Map ? (data['Host'] ?? data['Hosts'] ?? const []) : const []);
        final out = <HostRecord>[];
        for (final item in list is List ? list : const []) {
          if (item is! Map) continue;
          final mac = '${item['MACAddress'] ?? ''}'.toUpperCase().replaceAll('-', ':').trim();
          if (mac.length < 17) continue;
          final iface = '${item['InterfaceType'] ?? ''}'.toLowerCase();
          out.add(HostRecord(
            mac: mac,
            ip: '${item['IPAddress'] ?? ''}'.split(';').first.trim(),
            name: '${item['ActualName'] ?? item['HostName'] ?? ''}'.trim(),
            conn: iface.contains('wire') && !iface.contains('less') || iface == 'ethernet' ? 'Ethernet' : (iface.isEmpty ? '' : 'Wi-Fi'),
            active: item['Active'] == true || '${item['Active']}'.toLowerCase() == 'true' || '${item['Active']}' == '1',
            rxBytes: _int(item['RxKBytes']) * 1024,
            txBytes: _int(item['TxKBytes']) * 1024,
            downRate: _int(item['DownRate']),
            upRate: _int(item['UpRate']),
            hasCounters: item.containsKey('RxKBytes') || item.containsKey('TxKBytes'),
            isLocal: item['IsLocalDevice'] == true,
          ));
        }
        return out;
      });

  Future<WanStat> wan() => _relogin(() async {
        final t = _map(await get('monitoring/traffic-statistics'));
        return WanStat(
          totalRx: _int(t['TotalDownload']),
          totalTx: _int(t['TotalUpload']),
          downRate: _int(t['CurrentDownloadRate']),
          upRate: _int(t['CurrentUploadRate']),
        );
      });
}
