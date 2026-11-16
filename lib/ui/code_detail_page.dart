import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../data/dtc_database.dart';
import '../obd/dtc.dart';
import 'theme.dart';

final RegExp _codePattern = RegExp(r'^[PCBU][0-3][0-9A-F]{3}$');

/// Asks for a code and opens its description. Works without a car connected.
Future<void> showCodeLookup(BuildContext context, AppController controller) async {
  final input = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (context) {
      String? problem;
      return StatefulBuilder(
        builder: (context, setState) {
          void submit() {
            final value = input.text.trim().toUpperCase();
            if (_codePattern.hasMatch(value)) {
              Navigator.of(context).pop(value);
            } else {
              setState(() => problem = 'A code is a letter (P, C, B or U) and four characters, like P0420.');
            }
          }

          return AlertDialog(
            title: const Text('Look up a fault code'),
            content: TextField(
              controller: input,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              maxLength: 5,
              decoration: InputDecoration(hintText: 'P0420', errorText: problem, errorMaxLines: 3),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton(onPressed: submit, child: const Text('Look up')),
            ],
          );
        },
      );
    },
  );
  if (code == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CodeDetailPage(controller, code)));
}

/// Everything the offline database knows about one trouble code.
class CodeDetailPage extends StatelessWidget {
  const CodeDetailPage(this.controller, this.code, {super.key});

  final AppController controller;
  final String code;

  @override
  Widget build(BuildContext context) {
    final known = controller.dtc.contains(code);
    return Scaffold(
      appBar: AppBar(title: Text(code)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: FutureBuilder<DtcDetail?>(
            future: controller.dtc.detail(code),
            builder: (context, snapshot) {
              final detail = snapshot.data;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Text(
                    controller.dtc.title(code),
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
                  ),
                  const SizedBox(height: 6),
                  Text(describeDtcStructure(code), style: const TextStyle(color: kMuted)),
                  if (!known) ...[
                    const SizedBox(height: 16),
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'This code is defined by the vehicle manufacturer, so its exact meaning depends on the '
                          'make and model. The built-in database covers the generic codes shared by all makes.',
                          style: TextStyle(height: 1.45),
                        ),
                      ),
                    ),
                  ],
                  if (snapshot.connectionState != ConnectionState.done && known)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (detail != null) ..._detail(context, detail),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _detail(BuildContext context, DtcDetail detail) {
    String range(num? low, num? high, String Function(num) format) {
      if (low == null || high == null) return '';
      return low == high ? format(low) : '${format(low)} – ${format(high)}';
    }

    final cost = range(detail.costMinEur, detail.costMaxEur, (v) => '€${v.round()}');
    final hours = range(detail.hoursMin, detail.hoursMax, (v) => '$v h');
    final difficulty = switch (detail.difficulty) {
      'easy' => 'Easy',
      'medium' => 'Moderate',
      'hard' => 'Difficult',
      'shop_only' => 'Workshop only',
      _ => null,
    };

    return [
      const SizedBox(height: 14),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (detail.lightsWarningLamp) const _Tag('Lights the warning lamp', kWarn),
          if (detail.limpModePossible) const _Tag('May limit engine power', kCritical),
          if (detail.emissionsRelevant) const _Tag('Emissions relevant', kAccent),
        ],
      ),
      if (detail.description.isNotEmpty) ...[
        const SectionHeader('What it means'),
        Text(detail.description, style: const TextStyle(height: 1.5, fontSize: 15)),
      ],
      if (detail.symptoms.isNotEmpty) ...[
        const SectionHeader('What you may notice'),
        for (final symptom in detail.symptoms) _Bullet(symptom),
      ],
      if (detail.causes.isNotEmpty) ...[
        const SectionHeader('Likely causes'),
        Card(
          child: Column(
            children: [
              for (final (index, cause) in detail.causes.indexed) ...[
                if (index > 0) const Divider(indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(child: Text(cause.label, style: const TextStyle(height: 1.35))),
                      const SizedBox(width: 12),
                      _Tag(
                        switch (cause.likelihood) {
                          'high' => 'Most likely',
                          'medium' => 'Possible',
                          _ => 'Less likely',
                        },
                        switch (cause.likelihood) {
                          'high' => kWarn,
                          'medium' => kAccent,
                          _ => kMuted,
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
      if (difficulty != null || cost.isNotEmpty || hours.isNotEmpty) ...[
        const SectionHeader('Repair'),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                if (difficulty != null) _Fact('Difficulty', difficulty),
                if (detail.diyPossible != null)
                  _Fact('Do it yourself', detail.diyPossible! ? 'Possible' : 'Not recommended'),
                if (cost.isNotEmpty) _Fact('Typical cost', cost),
                if (hours.isNotEmpty) _Fact('Typical labour', hours),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'Cost and labour are rough European estimates and vary widely by vehicle.',
            style: TextStyle(color: kMuted, fontSize: 12.5),
          ),
        ),
      ],
      if (detail.relatedCodes.isNotEmpty) ...[
        const SectionHeader('Related codes'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final related in detail.relatedCodes)
              ActionChip(
                label: Text(related),
                onPressed: () =>
                    Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => CodeDetailPage(controller, related))),
              ),
          ],
        ),
      ],
    ];
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 8, right: 10, left: 4),
            child: SizedBox(
              width: 5,
              height: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(color: kMuted, shape: BoxShape.circle),
              ),
            ),
          ),
          Expanded(child: Text(text, style: const TextStyle(height: 1.45, fontSize: 15))),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: kMuted)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
