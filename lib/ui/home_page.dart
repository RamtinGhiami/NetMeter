import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../core/engine_tools.dart';
import '../core/web_server.dart';
import 'theme.dart';
import 'usage_explorer.dart';
import 'widgets.dart';

/// Overview: connection state, router usage today and this period, this PC, and a 14-day chart.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.engine, required this.web, required this.goTo});
  final Engine engine;
  final WebServer web;
  final ValueChanged<int> goTo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: engine,
        builder: (context, _) {
          final today = engine.sumWan(engine.today);
          final period = engine.sumWan(engine.periodStart);
          final pcToday = engine.sumPc(engine.today);
          final pcPeriod = engine.sumPc(engine.periodStart);
          final online = engine.hosts.where((h) => h.active).length;
          final text = Theme.of(context).textTheme;
          return SmoothList(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Row(children: [
                Expanded(child: Text('NetMeter', style: text.titleLarge)),
                _statusPill(),
                const SizedBox(width: 6),
                IconButton(tooltip: 'Open the dashboard in your browser', onPressed: web.open, icon: const Icon(Icons.open_in_browser_rounded, color: Palette.accent)),
              ]),
              const SizedBox(height: 12),
              if (engine.status != 'connected' && engine.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InfoCard(
                    background: Palette.cardHigh,
                    icon: Icons.info_outline_rounded,
                    title: engine.status == 'setup' ? 'Set up' : 'Not connected',
                    onTap: () => goTo(2),
                    child: Text(engine.error!, style: text.bodyMedium),
                  ),
                ),
              InfoCard(
                title: 'Router, today',
                icon: Icons.router_rounded,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(formatBytes(today.$1 + today.$2), style: text.headlineMedium),
                  const SizedBox(height: 4),
                  Text('Down ${formatBytes(today.$1)}   Up ${formatBytes(today.$2)}', style: text.bodySmall),
                  if (engine.wan != null) ...[
                    const SizedBox(height: 8),
                    Text('Now: down ${formatRate(engine.wan!.downRate)}, up ${formatRate(engine.wan!.upRate)}', style: text.bodySmall),
                  ],
                ]),
              ),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: InfoCard(
                    title: 'This period',
                    icon: Icons.calendar_month_rounded,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(formatBytes(period.$1 + period.$2), style: text.titleLarge),
                      Text('since ${_date(engine.periodStart)}', style: text.bodySmall),
                    ]),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InfoCard(
                    title: 'This PC',
                    icon: Icons.laptop_windows_rounded,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(engine.pcSupported ? formatBytes(pcToday.$1 + pcToday.$2) : 'n/a', style: text.titleLarge),
                      Text('today, ${formatBytes(pcPeriod.$1 + pcPeriod.$2)} period', style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              if (engine.config.quotaGb > 0) ...[
                _quotaCard(context),
                const SizedBox(height: 12),
              ],
              UsageExplorer(engine: engine),
              const SizedBox(height: 12),
              InfoCard(
                title: 'Router usage by month',
                icon: Icons.bar_chart_rounded,
                child: SizedBox(height: 140, child: CustomPaint(painter: _BarsPainter(engine.lastMonths(12), months: true), size: Size.infinite)),
              ),
              const SizedBox(height: 12),
              _topDevices(context),
              const SizedBox(height: 12),
              InfoCard(
                title: 'Devices',
                icon: Icons.devices_other_rounded,
                onTap: () => goTo(1),
                child: Text(
                  '$online online of ${engine.store.devices.length} known'
                  '${engine.perDeviceUsage ? '' : '\nThis router does not report traffic per device, so devices show connection time. This PC shows its own measured traffic.'}',
                  style: text.bodyMedium,
                ),
              ),
            ],
          );
        },
      );

  Widget _quotaCard(BuildContext context) {
    final q = engine.quota;
    final text = Theme.of(context).textTheme;
    final frac = q.cap == 0 ? 0.0 : (q.used / q.cap).clamp(0.0, 1.0);
    final over = q.projected > q.cap;
    return InfoCard(
      title: 'Allowance',
      icon: Icons.data_usage_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${formatBytes(q.used)} of ${formatBytes(q.cap)}', style: text.titleLarge),
        const SizedBox(height: 8),
        MeterBar(fraction: frac, color: q.used >= q.cap ? Palette.danger : (over ? Palette.warn : Palette.accent)),
        const SizedBox(height: 8),
        Text('At this pace: ${formatBytes(q.projected)} by the end of the period${over ? ' (over the allowance)' : ''}', style: text.bodySmall),
      ]),
    );
  }

  Widget _topDevices(BuildContext context) {
    final top = engine.topDevices(5);
    final text = Theme.of(context).textTheme;
    final maxV = top.isEmpty ? 1 : top.first.$2;
    return InfoCard(
      title: engine.perDeviceUsage ? 'Heaviest devices this period' : 'Most active devices this period',
      icon: Icons.leaderboard_rounded,
      onTap: () => goTo(1),
      child: top.isEmpty
          ? Text('No data yet.', style: text.bodyMedium)
          : Column(children: [
              for (final t in top)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(width: 120, child: Text(t.$1.display, style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Expanded(child: MeterBar(fraction: t.$2 / maxV)),
                    SizedBox(width: 64, child: Text(engine.perDeviceUsage ? formatBytes(t.$2) : formatSpan(t.$2), textAlign: TextAlign.end, style: text.bodySmall)),
                  ]),
                ),
            ]),
    );
  }

  Widget _statusPill() => switch (engine.status) {
        'connected' => const StatusPill('Connected', color: Palette.ok),
        'connecting' => const StatusPill('Connecting', color: Palette.warn),
        'blocked' => const StatusPill('Paused', color: Palette.danger),
        'offline' => const StatusPill('Router unreachable', color: Palette.warn),
        'error' => const StatusPill('Error', color: Palette.danger),
        _ => const StatusPill('Set up needed', color: Palette.warn),
      };
}

const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _date(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.data, {this.months = false});
  final List<(DateTime, int)> data;
  final bool months;

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = data.fold<int>(1, (m, e) => e.$2 > m ? e.$2 : m);
    const labelH = 16.0;
    final chartH = size.height - labelH;
    final slot = size.width / data.length;
    final bar = Paint()..color = Palette.accent;
    final dim = Paint()..color = Palette.cardHigh;
    for (var i = 0; i < data.length; i++) {
      final h = data[i].$2 == 0 ? 3.0 : (data[i].$2 / maxV * (chartH - 14)).clamp(3.0, chartH);
      final rect = RRect.fromRectAndRadius(Rect.fromLTWH(i * slot + slot * 0.18, chartH - h, slot * 0.64, h), const Radius.circular(4));
      canvas.drawRRect(rect, data[i].$2 == 0 ? dim : bar);
      if (months || i == data.length - 1 || i % 3 == 0) {
        final tp = TextPainter(
          text: TextSpan(text: months ? _monthNames[data[i].$1.month - 1] : '${data[i].$1.day}', style: const TextStyle(color: Palette.muted, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(i * slot + (slot - tp.width) / 2, chartH + 3));
      }
    }
    final top = TextPainter(
      text: TextSpan(text: 'max ${formatBytes(maxV)}', style: const TextStyle(color: Palette.muted, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    top.paint(canvas, Offset.zero);
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => true;
}
