/// Vehicle identification number validation and offline decoding (ISO 3779).
library;

final RegExp _vinPattern = RegExp(r'[A-HJ-NPR-Z0-9]{17}');

/// Finds a VIN in the bytes of a service 09 PID 02 response. Count bytes and
/// padding are not printable VIN characters, so they fall away on their own.
String? extractVin(List<int> data) {
  final text = String.fromCharCodes(data.skip(2).where((b) => (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A)));
  return _vinPattern.firstMatch(text)?.group(0);
}

class VinInfo {
  const VinInfo({
    required this.vin,
    required this.wmi,
    required this.country,
    required this.manufacturer,
    required this.modelYear,
    required this.checkDigitValid,
  });

  final String vin;

  /// World manufacturer identifier: the first three characters.
  final String wmi;
  final String? country;
  final String? manufacturer;

  /// Model year from position 10. Reliable for North American vehicles; many
  /// European manufacturers do not encode the year there.
  final int? modelYear;

  /// The position 9 check digit is only mandatory in North America and China.
  final bool checkDigitValid;

  String get summary {
    final parts = <String>[
      ?manufacturer,
      if (modelYear != null) '$modelYear',
      if (country != null) 'built in $country',
    ];
    return parts.isEmpty ? 'Unknown manufacturer' : parts.join(' · ');
  }
}

bool isValidVinFormat(String vin) => vin.length == 17 && _vinPattern.hasMatch(vin);

const Map<String, int> _transliteration = {
  'A': 1,
  'B': 2,
  'C': 3,
  'D': 4,
  'E': 5,
  'F': 6,
  'G': 7,
  'H': 8,
  'J': 1,
  'K': 2,
  'L': 3,
  'M': 4,
  'N': 5,
  'P': 7,
  'R': 9,
  'S': 2,
  'T': 3,
  'U': 4,
  'V': 5,
  'W': 6,
  'X': 7,
  'Y': 8,
  'Z': 9,
};

const List<int> _weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];

bool vinCheckDigitValid(String vin) {
  if (!isValidVinFormat(vin)) return false;
  var sum = 0;
  for (var i = 0; i < 17; i++) {
    final char = vin[i];
    final value = int.tryParse(char) ?? _transliteration[char];
    if (value == null) return false;
    sum += value * _weights[i];
  }
  final remainder = sum % 11;
  final expected = remainder == 10 ? 'X' : '$remainder';
  return vin[8] == expected;
}

const String _yearCodes = 'ABCDEFGHJKLMNPRSTVWXY123456789';

/// Position 10 repeats every 30 years (A = 1980 and 2010). Picks the latest
/// candidate that is not in the future, allowing next year's models.
int? vinModelYear(String vin, {int? currentYear}) {
  if (vin.length != 17) return null;
  final index = _yearCodes.indexOf(vin[9]);
  if (index < 0) return null;
  final limit = (currentYear ?? DateTime.now().year) + 1;
  int? year;
  for (var candidate = 1980 + index; candidate <= limit; candidate += 30) {
    year = candidate;
  }
  return year;
}

String? vinCountry(String vin) {
  if (vin.length < 2) return null;
  final first = vin[0];
  final second = vin[1];
  bool between(String low, String high) => second.compareTo(low) >= 0 && second.compareTo(high) <= 0;
  switch (first) {
    case '1' || '4' || '5':
      return 'United States';
    case '2':
      return 'Canada';
    case '3':
      return 'Mexico';
    case '6':
      return 'Australia';
    case '7':
      return between('A', 'E') ? 'New Zealand' : 'United States';
    case '8' || '9':
      return 'South America';
    case 'J':
      return 'Japan';
    case 'K':
      return 'South Korea';
    case 'L':
      return 'China';
    case 'M':
      return 'India / Southeast Asia';
    case 'N':
      return 'Turkey / Middle East';
    case 'S':
      if (between('A', 'M')) return 'United Kingdom';
      if (between('N', 'T')) return 'Germany';
      return 'Poland';
    case 'T':
      if (between('A', 'H')) return 'Switzerland';
      if (between('J', 'P')) return 'Czechia';
      if (between('R', 'V')) return 'Hungary';
      return 'Portugal';
    case 'U':
      if (between('U', 'Z')) return 'Romania';
      return 'Europe';
    case 'V':
      if (between('A', 'E')) return 'Austria';
      if (between('F', 'R')) return 'France';
      if (between('S', 'W')) return 'Spain';
      return 'Europe';
    case 'W':
      return 'Germany';
    case 'X':
      return 'Russia / Netherlands';
    case 'Y':
      if (between('A', 'E')) return 'Belgium';
      if (between('F', 'K')) return 'Finland';
      if (between('S', 'W')) return 'Sweden';
      return 'Northern Europe';
    case 'Z':
      return 'Italy';
  }
  if (first.compareTo('A') >= 0 && first.compareTo('H') <= 0) return 'Africa';
  return null;
}

/// Common world manufacturer identifiers. Three-character entries win over
/// two-character prefixes.
const Map<String, String> _manufacturers = {
  // North America
  '1G1': 'Chevrolet', '1GC': 'Chevrolet', '1GN': 'Chevrolet', '2G1': 'Chevrolet', '3GN': 'Chevrolet',
  '1G6': 'Cadillac', '1GY': 'Cadillac', '1GK': 'GMC', '1GT': 'GMC', '1G4': 'Buick',
  '1FA': 'Ford', '1FB': 'Ford', '1FD': 'Ford', '1FM': 'Ford', '1FT': 'Ford', '1ZV': 'Ford',
  '2FA': 'Ford', '2FM': 'Ford', '3FA': 'Ford', '1LN': 'Lincoln', '5LM': 'Lincoln',
  '1C3': 'Chrysler', '2C3': 'Chrysler', '1C4': 'Chrysler / Jeep / Dodge', '1C6': 'Ram', '3C6': 'Ram',
  '1J4': 'Jeep', '1J8': 'Jeep', '2B3': 'Dodge', '1B3': 'Dodge',
  '5YJ': 'Tesla', '7SA': 'Tesla', 'LRW': 'Tesla', 'XP7': 'Tesla',
  '1HG': 'Honda', '2HG': 'Honda', '5FN': 'Honda', '5J6': 'Honda', '19U': 'Acura', '19X': 'Honda',
  '1N4': 'Nissan', '1N6': 'Nissan', '5N1': 'Nissan', '3N1': 'Nissan',
  '4T1': 'Toyota', '2T1': 'Toyota', '5TD': 'Toyota', '5TF': 'Toyota', '2T2': 'Lexus', '2T3': 'Toyota',
  '1VW': 'Volkswagen', '3VW': 'Volkswagen', '4S3': 'Subaru', '4S4': 'Subaru',
  '4US': 'BMW', '5UX': 'BMW', '4JG': 'Mercedes-Benz', '55S': 'Mercedes-Benz',
  '5NP': 'Hyundai', '5NM': 'Hyundai', '5XY': 'Kia', '5XX': 'Kia',
  // Japan and Korea
  'JHM': 'Honda', 'JH4': 'Acura', 'JT': 'Toyota', 'JTH': 'Lexus', 'JTJ': 'Lexus',
  'JN': 'Nissan', 'JM': 'Mazda', 'JF': 'Subaru', 'JS': 'Suzuki',
  'JA3': 'Mitsubishi', 'JA4': 'Mitsubishi', 'JMB': 'Mitsubishi', 'JMY': 'Mitsubishi',
  'KMH': 'Hyundai', 'KM8': 'Hyundai', 'KNA': 'Kia', 'KND': 'Kia', 'KNM': 'Renault Samsung', 'KL': 'GM Korea',
  // United Kingdom
  'SAJ': 'Jaguar', 'SAL': 'Land Rover', 'SCC': 'Lotus', 'SCF': 'Aston Martin', 'SCB': 'Bentley',
  'SCA': 'Rolls-Royce', 'SB1': 'Toyota', 'SHH': 'Honda', 'SJN': 'Nissan', 'SFD': 'Alexander Dennis',
  // Central Europe
  'TMB': 'Škoda', 'TRU': 'Audi', 'TSM': 'Suzuki', 'TMA': 'Hyundai', 'U5Y': 'Kia', 'UU1': 'Dacia',
  // France and Spain
  'VF1': 'Renault', 'VF3': 'Peugeot', 'VF7': 'Citroën', 'VR1': 'DS Automobiles', 'VR3': 'Peugeot',
  'VR7': 'Citroën', 'VNK': 'Toyota', 'VSS': 'SEAT', 'VSK': 'Nissan', 'VS6': 'Ford', 'VF6': 'Renault Trucks',
  // Germany
  'W0L': 'Opel', 'W0V': 'Opel', 'WAU': 'Audi', 'WA1': 'Audi', 'WUA': 'Audi Sport',
  'WBA': 'BMW', 'WBS': 'BMW M', 'WBY': 'BMW i', 'WBX': 'BMW', 'WMW': 'MINI',
  'WDB': 'Mercedes-Benz', 'WDC': 'Mercedes-Benz', 'WDD': 'Mercedes-Benz', 'WDF': 'Mercedes-Benz',
  'W1K': 'Mercedes-Benz', 'W1N': 'Mercedes-Benz', 'W1V': 'Mercedes-Benz', 'WME': 'smart',
  'WP0': 'Porsche', 'WP1': 'Porsche', 'WVW': 'Volkswagen', 'WVG': 'Volkswagen',
  'WV1': 'Volkswagen Commercial', 'WV2': 'Volkswagen Commercial', 'WF0': 'Ford',
  // Nordics and Italy
  'YS3': 'Saab', 'YV1': 'Volvo', 'YV4': 'Volvo', 'YK1': 'Saab',
  'ZAR': 'Alfa Romeo', 'ZFA': 'Fiat', 'ZFF': 'Ferrari', 'ZHW': 'Lamborghini', 'ZAM': 'Maserati',
  'ZLA': 'Lancia', 'ZCF': 'Iveco',
  // China
  'LFV': 'FAW-Volkswagen', 'LSV': 'SAIC Volkswagen', 'LBV': 'BMW Brilliance', 'LVS': 'Ford',
};

String? vinManufacturer(String vin) {
  if (vin.length < 3) return null;
  return _manufacturers[vin.substring(0, 3)] ?? _manufacturers[vin.substring(0, 2)];
}

VinInfo? decodeVin(String rawVin, {int? currentYear}) {
  final vin = rawVin.trim().toUpperCase();
  if (!isValidVinFormat(vin)) return null;
  return VinInfo(
    vin: vin,
    wmi: vin.substring(0, 3),
    country: vinCountry(vin),
    manufacturer: vinManufacturer(vin),
    modelYear: vinModelYear(vin, currentYear: currentYear),
    checkDigitValid: vinCheckDigitValid(vin),
  );
}
