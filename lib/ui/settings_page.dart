import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../core/engine.dart';
import '../core/engine_tools.dart';
import '../core/web_server.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.engine, required this.web});
  final Engine engine;
  final WebServer web;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _host = TextEditingController(text: widget.engine.config.host);
  late final _user = TextEditingController(text: widget.engine.config.username);
  late final _pass = TextEditingController(text: widget.engine.config.password);
  late final _quota = TextEditingController(text: widget.engine.config.quotaGb == 0 ? '' : '${widget.engine.config.quotaGb}');
  late int _interval = widget.engine.config.intervalSec;
  late int _resetDay = widget.engine.config.resetDay;
  late bool _autostart = widget.engine.config.autostart;
  bool _show = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    final text = Theme.of(context).textTheme;
    return SmoothList(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        Text('Settings', style: text.titleLarge),
        const SizedBox(height: 12),
        InfoCard(
          title: 'Router',
          icon: Icons.router_rounded,
          child: Column(children: [
            TextField(controller: _host, decoration: const InputDecoration(labelText: 'Router address')),
            const SizedBox(height: 10),
            TextField(controller: _user, decoration: const InputDecoration(labelText: 'Username (case matters, usually Admin)')),
            const SizedBox(height: 10),
            TextField(
              controller: _pass,
              obscureText: !_show,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 20), onPressed: () => setState(() => _show = !_show)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The password is stored encrypted for this Windows user. A wrong password is tried once, then NetMeter stops, because the router locks logins after a few failures.',
              style: text.bodySmall,
            ),
          ]),
        ),
        const SizedBox(height: 12),
        InfoCard(
          title: 'Recording',
          icon: Icons.timer_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Check the router every', style: text.bodySmall),
            const SizedBox(height: 6),
            Segmented<int>(
              value: _interval,
              onChanged: (v) => setState(() => _interval = v),
              options: const [(10, '10 s', Icons.bolt_rounded), (20, '20 s', Icons.timer_rounded), (60, '1 min', Icons.timer_outlined)],
            ),
            const SizedBox(height: 14),
            Text('Billing period starts on day', style: text.bodySmall),
            Row(children: [
              Expanded(child: Slider(min: 1, max: 28, divisions: 27, value: _resetDay.toDouble(), onChanged: (v) => setState(() => _resetDay = v.round()))),
              SizedBox(width: 28, child: Text('$_resetDay', textAlign: TextAlign.end)),
            ]),
            const SizedBox(height: 4),
            TextField(
              controller: _quota,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Monthly allowance in GB (optional, for the forecast and alerts)'),
            ),
            const SizedBox(height: 10),
            ToggleTile(title: 'Start with Windows', subtitle: 'Runs quietly in the tray', value: _autostart, onChanged: (v) => setState(() => _autostart = v)),
          ]),
        ),
        const SizedBox(height: 16),
        ListenableBuilder(
          listenable: e,
          builder: (context, _) => Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: () async {
                  await e.applySettings(host: _host.text, username: _user.text, password: _pass.text, intervalSec: _interval, resetDay: _resetDay, autostart: _autostart, quotaGb: int.tryParse(_quota.text) ?? 0);
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
                },
                child: const Text('Save and connect'),
              ),
            ),
            if (e.authBlocked) ...[
              const SizedBox(width: 10),
              OutlinedButton(onPressed: e.retryLogin, child: const Text('Try again')),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: widget.web.open, icon: const Icon(Icons.open_in_browser_rounded, size: 18), label: const Text('Open in browser'))),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {
                final folder = e.exportCsv();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CSV files saved to $folder')));
              },
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Export CSV'),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Text('NetMeter ${e.version}. Data is kept in %APPDATA%\\NetMeter', style: text.bodySmall),
      ],
    );
  }
}
