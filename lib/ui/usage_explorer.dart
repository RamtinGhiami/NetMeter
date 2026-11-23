import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../core/engine_tools.dart';
import 'theme.dart';
import 'widgets.dart';

/// Pick a day or a month (billing period) and see its usage: totals, a chart and the most active devices.
class UsageExplorer extends StatefulWidget {
  const UsageExplorer({super.key, required this.engine});
  final Engine engine;

  @override
  State<UsageExplorer> createState() => _UsageExplorerState();
}

class _UsageExplorerState extends State<UsageExplorer> {
  bool _month = false;
  int _offset = 0; // 0 = today or this period, -1 = the one before, ...

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final v = widget.engine.usageView(month: _month, offset: _offset);
    final bars = (v['bars'] as List).cast<Map<String, dynamic>>();
    final top = (v['top'] as List).cast<Map<String, dynamic>>();
    final topIsBytes = v['topIsBytes'] as bool;
    final maxTop = top.isEmpty ? 1 : (top.first['value'] as int);
    return InfoCard(
      title: 'Usage by day or month',
      icon: Icons.insights_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Segmented<bool>(
          value: _month,
          onChanged: (m) => setState(() {
            _month = m;
            _offset = 0;
          }),
          options: const [(false, 'Day', Icons.today_rounded), (true, 'Month', Icons.calendar_month_rounded)],
        ),
        const SizedBox(height: 8),
        Row(children: [
          IconButton(onPressed: v['older'] == true ? () => setState(() => _offset--) : null, icon: const Icon(Icons.chevron_left_rounded)),
          Expanded(child: Text(v['title'] as String, textAlign: TextAlign.center, style: text.titleMedium)),
          IconButton(onPressed: _offset < 0 ? () => setState(() => _offset++) : null, icon: const Icon(Icons.chevron_right_rounded)),
        ]),
        const SizedBox(height: 4),
        Text(formatBytes((v['down'] as int) + (v['up'] as int)), style: text.headlineMedium),
        Text('Down ${formatBytes(v['down'] as int)}   Up ${formatBytes(v['up'] as int)}   This PC ${formatBytes(v['pc'] as int)}', style: text.bodySmall),
        const SizedBox(height: 12),
        SizedBox(height: 120, child: CustomPaint(painter: _Bars(bars), size: Size.infinite)),
        if (top.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(topIsBytes ? 'Heaviest devices' : 'Most active devices (connection time)', style: text.bodySmall),
          const SizedBox(height: 4),
          for (final t in top)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(width: 110, child: Text(t['name'] as String, style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
                Expanded(child: MeterBar(fraction: (t['value'] as int) / maxTop)),
                SizedBox(width: 64, child: Text(topIsBytes ? formatBytes(t['value'] as int) : formatSpan(t['value'] as int), textAlign: TextAlign.end, style: text.bodySmall)),
              ]),
            ),
        ],
      ]),
    );
  }
}

class _Bars extends CustomPainter {
  _Bars(this.bars);
  final List<Map<String, dynamic>> bars;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final maxV = bars.fold<int>(1, (m, e) => (e['bytes'] as int) > m ? e['bytes'] as int : m);
    const labelH = 16.0;
    final chartH = size.height - labelH;
    final slot = size.width / bars.length;
    final bar = Paint()..color = Palette.accent;
    final dim = Paint()..color = Palette.cardHigh;
    final every = bars.length > 24 ? 5 : 3;
    for (var i = 0; i < bars.length; i++) {
      final v = bars[i]['bytes'] as int;
      final h = v == 0 ? 3.0 : (v / maxV * (chartH - 14)).clamp(3.0, chartH);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * slot + slot * 0.15, chartH - h, slot * 0.7, h), const Radius.circular(3)), v == 0 ? dim : bar);
      if (i % every == 0) {
        final tp = TextPainter(text: TextSpan(text: bars[i]['label'] as String, style: const TextStyle(color: Palette.muted, fontSize: 10)), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, Offset(i * slot + (slot - tp.width) / 2, chartH + 3));
      }
    }
    final top = TextPainter(text: TextSpan(text: 'max ${formatBytes(maxV)}', style: const TextStyle(color: Palette.muted, fontSize: 10)), textDirection: TextDirection.ltr)..layout();
    top.paint(canvas, Offset.zero);
  }

  @override
  bool shouldRepaint(covariant _Bars old) => true;
}
