// A small local web server so the dashboard can also be opened in a browser: http://127.0.0.1:47854/
// It listens on the loopback address only. Changes (device names) need a custom header, so another web page cannot send them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'engine.dart';
import 'engine_tools.dart';
import 'platform_utils.dart';

class WebServer {
  WebServer(this.engine);
  final Engine engine;
  HttpServer? _server;
  String _html = '';
  int port = 0;

  String get url => 'http://127.0.0.1:$port/';
  bool get running => _server != null;

  Future<void> start() async {
    _html = await rootBundle.loadString('assets/dashboard.html');
    for (var p = 47854; p < 47864; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
        port = p;
        break;
      } on SocketException {
        continue;
      }
    }
    _server?.listen(_handle, onError: (_) {});
  }

  Future<void> open() async {
    if (!running) return;
    await openUrl(url);
  }

  Future<void> stop() async => _server?.close(force: true);

  void _send(HttpResponse r, int code, String type, String body) {
    r.statusCode = code;
    r.headers
      ..set('Content-Type', '$type; charset=utf-8')
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Content-Security-Policy', "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'");
    r.write(body);
    r.close();
  }

  Future<void> _handle(HttpRequest r) async {
    try {
      final host = r.headers.host;
      if (host != '127.0.0.1' && host != 'localhost') return _send(r.response, 403, 'text/plain', 'forbidden');
      final path = r.uri.path;
      if (r.method == 'GET' && path == '/') return _send(r.response, 200, 'text/html', _html);
      if (r.method == 'GET' && path == '/api/state') return _send(r.response, 200, 'application/json', jsonEncode(engine.stateJson()));
      if (r.method == 'POST' && r.headers.value('x-netmeter') == '1') {
        if (path == '/api/device') {
          final j = jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
          engine.setDeviceMeta('${j['mac']}', name: j['name'] as String?, category: j['category'] as String?);
          return _send(r.response, 200, 'application/json', jsonEncode(engine.stateJson()));
        }
        if (path == '/api/export') {
          return _send(r.response, 200, 'application/json', jsonEncode({'folder': engine.exportCsv()}));
        }
      }
      _send(r.response, 404, 'text/plain', 'not found');
    } catch (e) {
      engine.log('web error: $e');
      try {
        _send(r.response, 500, 'text/plain', 'error');
      } catch (_) {}
    }
  }
}
