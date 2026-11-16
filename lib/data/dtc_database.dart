import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../obd/dtc.dart';

class DtcCause {
  const DtcCause(this.label, this.likelihood);

  final String label;

  /// "high", "medium" or "low".
  final String likelihood;
}

class DtcDetail {
  const DtcDetail({
    required this.description,
    required this.causes,
    required this.symptoms,
    required this.difficulty,
    required this.diyPossible,
    required this.costMinEur,
    required this.costMaxEur,
    required this.hoursMin,
    required this.hoursMax,
    required this.lightsWarningLamp,
    required this.emissionsRelevant,
    required this.limpModePossible,
    required this.relatedCodes,
  });

  final String description;
  final List<DtcCause> causes;
  final List<String> symptoms;
  final String? difficulty;
  final bool? diyPossible;
  final num? costMinEur;
  final num? costMaxEur;
  final num? hoursMin;
  final num? hoursMax;
  final bool lightsWarningLamp;
  final bool emissionsRelevant;
  final bool limpModePossible;
  final List<String> relatedCodes;

  static DtcDetail fromJson(Map<String, dynamic> json) {
    final repair = (json['r'] as List?) ?? const [];
    final flags = (json['f'] as List?) ?? const [];
    T? at<T>(List list, int index) => index < list.length && list[index] is T ? list[index] as T : null;
    return DtcDetail(
      description: json['d'] as String? ?? '',
      causes: [
        for (final cause in (json['c'] as List?) ?? const [])
          if (cause is List && cause.length >= 2) DtcCause('${cause[0]}', '${cause[1]}'),
      ],
      symptoms: [for (final symptom in (json['s'] as List?) ?? const []) '$symptom'],
      difficulty: at<String>(repair, 0),
      diyPossible: at<bool>(repair, 1),
      costMinEur: at<num>(repair, 2),
      costMaxEur: at<num>(repair, 3),
      hoursMin: at<num>(repair, 4),
      hoursMax: at<num>(repair, 5),
      lightsWarningLamp: at<bool>(flags, 0) ?? false,
      emissionsRelevant: at<bool>(flags, 1) ?? false,
      limpModePossible: at<bool>(flags, 3) ?? false,
      relatedCodes: [for (final code in (json['x'] as List?) ?? const []) '$code'],
    );
  }
}

/// Offline database of the 9,533 generic OBD-II trouble codes, from the
/// public-domain OBDex dataset. Titles load at start-up; the longer
/// descriptions load per code family the first time one is opened.
class DtcDatabase {
  DtcDatabase({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  Map<String, dynamic> _titles = const {};
  final Map<String, Future<Map<String, dynamic>>> _families = {};

  bool get isLoaded => _titles.isNotEmpty;

  int get codeCount => _titles.length;

  Future<void> load() async {
    if (isLoaded) return;
    _titles = jsonDecode(await _bundle.loadString('assets/dtc/titles.json')) as Map<String, dynamic>;
  }

  bool contains(String code) => _titles.containsKey(code.toUpperCase());

  /// The short title of a code, or a structural description for codes that
  /// are not in the database (manufacturer-specific ones).
  String title(String code) {
    final entry = _titles[code.toUpperCase()];
    if (entry is List && entry.isNotEmpty) return '${entry[0]}';
    return describeDtcStructure(code.toUpperCase());
  }

  Future<DtcDetail?> detail(String rawCode) async {
    final code = rawCode.toUpperCase();
    if (!contains(code)) return null;
    final family = code.substring(0, 2);
    final entries = await _families.putIfAbsent(family, () async {
      try {
        return jsonDecode(await _bundle.loadString('assets/dtc/detail_$family.json')) as Map<String, dynamic>;
      } catch (_) {
        return const <String, dynamic>{};
      }
    });
    final json = entries[code];
    return json is Map<String, dynamic> ? DtcDetail.fromJson(json) : null;
  }
}
