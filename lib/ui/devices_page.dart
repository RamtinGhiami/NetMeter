import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../core/store.dart';
import 'theme.dart';
import 'widgets.dart';

/// Every device the router has shown, with the name and category you gave it.
class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, required this.engine});
  final Engine engine;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: engine,
        builder: (context, _) {
          final list = engine.store.devices.values.toList()
            ..sort((a, b) {
              if (a.online != b.online) return a.online ? -1 : 1;
              return a.display.toLowerCase().compareTo(b.display.toLowerCase());
            });
          return SmoothList(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Text('Devices', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('Tap a device to name it and pick a category.', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              if (list.isEmpty) InfoCard(child: Text('No devices yet. They appear after the first successful connection.', style: Theme.of(context).textTheme.bodyMedium)),
              for (final d in list) Padding(padding: const EdgeInsets.only(bottom: 10), child: _tile(context, d)),
            ],
          );
        },
      );

  Widget _tile(BuildContext context, Device d) {
    final s = engine.deviceStats(d.mac);
    final usage = (engine.perDeviceUsage || d.isLocal) ? '${formatBytes(s.bytesToday)} today' : 'online ${formatSpan(s.secsToday)} today';
    return InfoCard(
      onTap: () => _edit(context, d),
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: Palette.cardHigh, borderRadius: BorderRadius.circular(12)),
          child: Icon(_icon(d.category, d.conn), size: 22, color: d.online ? Palette.accent : Palette.muted),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.display + (d.isLocal ? '  (this PC)' : ''), style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text([if (d.category.isNotEmpty) d.category, d.conn, d.ip, usage].where((e) => e.isNotEmpty).join(', '), style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        StatusPill(d.online ? 'Online' : 'Offline', color: d.online ? Palette.ok : Palette.muted),
      ]),
    );
  }

  IconData _icon(String cat, String conn) => switch (cat) {
        'Phone' => Icons.smartphone_rounded,
        'Computer' => Icons.computer_rounded,
        'Tablet' => Icons.tablet_rounded,
        'TV' => Icons.tv_rounded,
        'Console' => Icons.sports_esports_rounded,
        'Smart home' => Icons.lightbulb_rounded,
        'Guest' => Icons.person_outline_rounded,
        _ => conn == 'Ethernet' ? Icons.settings_ethernet_rounded : Icons.wifi_rounded,
      };

  Future<void> _edit(BuildContext context, Device d) async {
    final nameCtl = TextEditingController(text: d.name);
    var cat = d.category;
    final s = engine.deviceStats(d.mac);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: Palette.card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(d.display),
          content: SizedBox(
            width: 340,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '${d.mac}\n${d.ip}  ${d.conn}\nOnline this period: ${formatSpan(s.secsPeriod)}'
                '${engine.perDeviceUsage || d.isLocal ? '\nUsage this period: ${formatBytes(s.bytesPeriod)}' : ''}',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              TextField(controller: nameCtl, maxLength: 40, decoration: InputDecoration(labelText: 'Name', hintText: d.hostName)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final c in categories)
                  ChoiceChip(
                    selected: cat == c,
                    label: Text(c),
                    showCheckmark: false,
                    selectedColor: Palette.accent,
                    backgroundColor: Palette.cardHigh,
                    side: BorderSide.none,
                    labelStyle: TextStyle(color: cat == c ? Colors.white : Palette.muted, fontWeight: FontWeight.w600),
                    onSelected: (_) => setState(() => cat = cat == c ? '' : c),
                  ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                engine.setDeviceMeta(d.mac, name: nameCtl.text, category: cat);
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
