import 'dart:typed_data';

enum CpuTransitInfoProfile {
  cityUnion([0xA0, 0, 0, 0, 3, 0x86, 0x98, 7, 1]),
  tUnion([0xA0, 0, 0, 6, 0x32, 1, 1, 5]);

  const CpuTransitInfoProfile(this.aid);
  final List<int> aid;
  static const infoSfi = 0x15;

  static CpuTransitInfoProfile? forAid(List<int>? aid) {
    if (aid == null) return null;
    for (final profile in values) {
      if (profile.aid.length == aid.length &&
          Iterable<int>.generate(aid.length)
              .every((i) => profile.aid[i] == aid[i])) {
        return profile;
      }
    }
    return null;
  }
}

typedef CpuTransitInfo = ({
  int version,
  String? cityCode,
  String? issued,
  String? expires,
});

String _hex(List<int> data) => data
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join()
    .toUpperCase();

String? _bcdDate(Uint8List data, int start) {
  final date = _hex(data.sublist(start, start + 4));
  if (!RegExp(r'^[0-9]{8}$').hasMatch(date)) return null;
  final y = int.parse(date.substring(0, 4));
  final m = int.parse(date.substring(4, 6));
  final d = int.parse(date.substring(6, 8));
  if (y == 0) return null;
  final value = DateTime.utc(y, m, d);
  return value.year == y && value.month == m && value.day == d
      ? '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}'
      : null;
}

/// Public SFI 0x15 layouts observed by NFCard CityUnion/TUnion. Keep
/// absent/invalid dates unknown, and do not infer a card number format.
CpuTransitInfo parseCpuTransitInfo(
  CpuTransitInfoProfile profile,
  Uint8List data,
) {
  if (data.length < 30)
    throw const FormatException('Incomplete transit info EF');
  final cityCode = profile == CpuTransitInfoProfile.cityUnion
      ? _hex(data.sublist(2, 4))
      : null;
  return (
    version: data[9],
    cityCode: cityCode == '0000' || cityCode == 'FFFF' ? null : cityCode,
    issued: _bcdDate(data, 20),
    expires: _bcdDate(data, 24),
  );
}
