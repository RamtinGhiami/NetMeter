import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/engine.dart';
import 'core/platform_utils.dart';
import 'core/web_server.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

const appVersion = '0.4.2';
const _instancePort = 47853; // single-instance socket (not shared with any other app)

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final demo = args.contains('--demo'); // made-up data, for screenshots
  final page = int.tryParse(args.where((a) => a.startsWith('--page=')).map((a) => a.substring(7)).firstOrNull ?? '') ?? 0;

  // one copy only: a second start asks the first one to show its window
  ServerSocket? lock;
  try {
    lock = await ServerSocket.bind(InternetAddress.loopbackIPv4, demo ? 47890 : _instancePort);
  } on SocketException {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, _instancePort, timeout: const Duration(seconds: 2));
      s.write('show');
      await s.flush();
      await s.close();
    } catch (_) {}
    exit(0);
  }

  final minimized = args.contains('--minimized');
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(460, 690),
    minimumSize: Size(460, 690),
    maximumSize: Size(460, 690),
    center: true,
    title: 'NetMeter',
    titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Palette.background,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setPreventClose(true);
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    if (!minimized) {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  LaunchAtStartup.instance.setup(appName: 'NetMeterApp', appPath: Platform.resolvedExecutable, args: const ['--minimized'], packageName: 'com.netmeter.netmeter');
  final engine = Engine(
    demo: demo,
    version: appVersion,
    onAutostart: (on) async {
      if (on) {
        await LaunchAtStartup.instance.enable();
      } else {
        await LaunchAtStartup.instance.disable();
      }
    },
  );
  await engine.start();
  final web = WebServer(engine);
  await web.start();
  final host = _TrayHost(engine, web);
  if (!demo) await host.init();
  lock.listen((client) {
    client.listen((_) => host.showWindow());
  });

  FlutterError.onError = (details) => engine.log('ui error: ${details.exceptionAsString()}');
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    engine.log('error: $error');
    return true;
  };

  final shot = args.where((a) => a.startsWith('--screenshot=')).map((a) => a.substring(13)).firstOrNull;
  runApp(RepaintBoundary(key: _shotKey, child: NetMeterApp(engine: engine, web: web, page: page)));
  if (shot != null) unawaited(_saveScreenshot(shot));
}

final _shotKey = GlobalKey();

/// For the README: renders the app's own frame to a PNG (no desktop in it) and exits.
Future<void> _saveScreenshot(String path) async {
  await Future<void>.delayed(const Duration(seconds: 3));
  final boundary = _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
  exit(0);
}

class NetMeterApp extends StatelessWidget {
  const NetMeterApp({super.key, required this.engine, required this.web, this.page = 0});
  final Engine engine;
  final WebServer web;
  final int page;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NetMeter',
        debugShowCheckedModeBanner: false,
        locale: const Locale('en', 'US'), // numbers and dates stay English whatever the system language is
        theme: buildTheme(),
        home: Shell(engine: engine, web: web, initialPage: page),
      );
}

/// The tray icon and the close button: closing hides the window, the tray menu quits for real.
class _TrayHost with TrayListener, WindowListener {
  _TrayHost(this.engine, this.web);
  final Engine engine;
  final WebServer web;

  Future<void> init() async {
    windowManager.addListener(this);
    trayManager.addListener(this);
    final icon = trayIconPath();
    if (File(icon).existsSync()) await trayManager.setIcon(icon);
    await trayManager.setToolTip('NetMeter');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Open NetMeter'),
      MenuItem(key: 'browser', label: 'Open dashboard in browser'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit (stops recording)'),
    ]));
  }

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    // a window shown after hours in the tray can come back blank: ask for a frame, then nudge the size
    WidgetsBinding.instance.scheduleForcedFrame();
    final size = await windowManager.getSize();
    await windowManager.setSize(Size(size.width + 1, size.height));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await windowManager.setSize(size);
    WidgetsBinding.instance.scheduleForcedFrame();
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    switch (item.key) {
      case 'open':
        await showWindow();
      case 'browser':
        await web.open();
      case 'quit':
        await engine.shutdown();
        await trayManager.destroy();
        exit(0);
    }
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }
}
