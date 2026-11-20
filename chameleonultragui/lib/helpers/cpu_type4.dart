import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/cpu_card_access.dart';

const cpuType4Aid = [0xD2, 0x76, 0, 0, 0x85, 1, 1];
const cpuType4CcFid = 0xE103;

class CpuType4File {
  final int fid, capacity, readAccess, writeAccess;
  final int? lengthBytes;
  const CpuType4File(
    this.fid,
    this.capacity,
    this.readAccess,
    this.writeAccess, {
    this.lengthBytes,
  });
}

typedef CpuType4Header = ({int size, int version, int maxRead, int maxWrite});
typedef CpuType4Capability = ({
  CpuType4Header header,
  List<CpuType4File> files,
});

int _uint(List<int> data, int start, int length) {
  var value = 0;
  for (var i = start; i < start + length; i++) {
    value = value * 256 + data[i];
  }
  return value;
}

CpuType4Header parseCpuType4Header(Uint8List bytes) {
  if (bytes.length < 7) throw const FormatException('Missing CC header');
  final size = _uint(bytes, 0, 2);
  final version = bytes[2];
  final maxRead = _uint(bytes, 3, 2);
  if (size < 15 || maxRead < 15 || !const {1, 2, 3}.contains(version >> 4)) {
    throw const FormatException('Invalid CC header');
  }
  return (
    size: size,
    version: version,
    maxRead: maxRead,
    maxWrite: _uint(bytes, 5, 2),
  );
}

CpuType4Capability parseCpuType4Capability(Uint8List bytes) {
  final header = parseCpuType4Header(bytes);
  if (header.size > bytes.length) {
    throw const FormatException('Incomplete CC');
  }
  final files = <CpuType4File>[];
  final ids = <int>{cpuType4CcFid, 0, 0x3F00, 0x3FFF, 0xFFFF};
  for (var i = 7; i < header.size;) {
    final tag = bytes[i++];
    if (tag == 0) continue;
    if (tag == 0xFE) break;
    if (i >= header.size) throw const FormatException('Missing CC TLV length');
    var length = bytes[i++];
    if (length == 0xFF) {
      if (i + 2 > header.size) {
        throw const FormatException('Incomplete CC TLV length');
      }
      length = _uint(bytes, i, 2);
      i += 2;
    }
    final end = i + length;
    if (end > header.size) throw const FormatException('Truncated CC TLV');
    if (tag == 4 || tag == 5 || tag == 6) {
      final extended = tag == 6;
      if (length != (extended ? 8 : 6)) {
        throw const FormatException('Invalid file control TLV');
      }
      final fid = _uint(bytes, i, 2);
      final capacity = _uint(bytes, i + 2, extended ? 4 : 2);
      final lengthBytes = extended ? 4 : (tag == 4 ? 2 : null);
      if (capacity >= (lengthBytes ?? 1) && ids.add(fid)) {
        files.add(
          CpuType4File(
            fid,
            capacity,
            bytes[end - 2],
            bytes[end - 1],
            lengthBytes: lengthBytes,
          ),
        );
      }
    }
    i = end;
  }
  return (header: header, files: List.unmodifiable(files));
}

/// Read only the standardized CC, within the advertised short-read limit.
Future<CpuFileReply> readCpuType4Capability(CpuCardAccess card) async {
  final first = await card.readBinary(0, 15);
  final header = parseCpuType4Header(first.data);
  if (first.data.length != 15 || header.size > 1024) {
    throw const FormatException('CC beyond preview limit');
  }
  if (header.size == 15) return first;
  final remaining = await card.readBinaryRange(
    15,
    header.size - 15,
    maxBlock: math.min(256, header.maxRead),
  );
  return CpuFileReply.fromData(
    Uint8List.fromList([...first.data, ...remaining.data]),
    remaining.status,
  );
}

int cpuNdefLength(Uint8List bytes, int lengthBytes) {
  if ((lengthBytes != 2 && lengthBytes != 4) || bytes.length < lengthBytes) {
    throw const FormatException('Missing NLEN/ENLEN');
  }
  return _uint(bytes, 0, lengthBytes);
}

typedef CpuNdefRecord = ({
  int tnf,
  String type,
  Uint8List id,
  int payloadLength,
  String? text,
  String? language,
  String? uri,
});

const _uriPrefixes = [
  '',
  'http://www.',
  'https://www.',
  'http://',
  'https://',
  'tel:',
  'mailto:',
  'ftp://anonymous:anonymous@',
  'ftp://ftp.',
  'ftps://',
  'sftp://',
  'smb://',
  'nfs://',
  'ftp://',
  'dav://',
  'news:',
  'telnet://',
  'imap:',
  'rtsp://',
  'urn:',
  'pop:',
  'sip:',
  'sips:',
  'tftp:',
  'btspp://',
  'btl2cap://',
  'btgoep://',
  'tcpobex://',
  'irdaobex://',
  'file://',
  'urn:epc:id:',
  'urn:epc:tag:',
  'urn:epc:pat:',
  'urn:epc:raw:',
  'urn:epc:',
  'urn:nfc:',
];

String _utf16(Uint8List bytes) {
  if (bytes.length.isOdd) throw const FormatException('Odd UTF-16 length');
  final little = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE;
  final bom =
      little || (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF);
  final units = <int>[];
  for (var i = bom ? 2 : 0; i < bytes.length; i += 2) {
    units.add(little ? bytes[i] | bytes[i + 1] << 8 : _uint(bytes, i, 2));
  }
  for (var i = 0; i < units.length; i++) {
    if (units[i] >= 0xD800 && units[i] <= 0xDBFF) {
      if (++i == units.length || units[i] < 0xDC00 || units[i] > 0xDFFF) {
        throw const FormatException('Invalid UTF-16 surrogate pair');
      }
    } else if (units[i] >= 0xDC00 && units[i] <= 0xDFFF) {
      throw const FormatException('Invalid UTF-16 surrogate');
    }
  }
  return String.fromCharCodes(units);
}

/// Decode a complete NFC Forum message, without launching its URI or reading
/// a payload from outside NLEN/ENLEN. Distinct from APDU transport chunking.
List<CpuNdefRecord> parseCpuNdefMessage(Uint8List message) {
  final records = <CpuNdefRecord>[];
  var offset = 0;
  while (offset < message.length) {
    if (message.length - offset < 3) {
      throw const FormatException('Truncated NDEF header');
    }
    final header = message[offset++];
    final begin = header & 0x80 != 0, end = header & 0x40 != 0;
    final tnf = header & 7;
    if (begin != records.isEmpty || header & 0x20 != 0 || tnf >= 6) {
      throw const FormatException('Invalid or chunked NDEF record');
    }
    final typeLength = message[offset++];
    final sizeWidth = header & 0x10 != 0 ? 1 : 4;
    final hasId = header & 0x08 != 0;
    if (sizeWidth + (hasId ? 1 : 0) > message.length - offset) {
      throw const FormatException('Truncated NDEF record length');
    }
    final size = _uint(message, offset, sizeWidth);
    offset += sizeWidth;
    final idLength = hasId ? message[offset++] : 0;
    if (typeLength + idLength + size > message.length - offset ||
        (tnf == 0 && typeLength + idLength + size != 0) ||
        (tnf == 5 && typeLength != 0)) {
      throw const FormatException('Inconsistent NDEF record length');
    }
    final type = ascii.decode(message.sublist(offset, offset + typeLength));
    offset += typeLength;
    final id = message.sublist(offset, offset + idLength);
    offset += idLength;
    final payload = Uint8List.sublistView(message, offset, offset + size);
    offset += size;
    String? text, language, uri;
    if (tnf == 1 && type == 'T') {
      if (size == 0 || payload[0] & 0x40 != 0) {
        throw const FormatException('Invalid NDEF Text status byte');
      }
      final length = payload[0] & 0x3F;
      if (length + 1 > size) {
        throw const FormatException('Truncated NDEF Text language');
      }
      language = ascii.decode(payload.sublist(1, length + 1));
      final value = Uint8List.sublistView(payload, length + 1);
      text = payload[0] & 0x80 == 0 ? utf8.decode(value) : _utf16(value);
    } else if (tnf == 1 && type == 'U') {
      if (size == 0 || payload[0] >= _uriPrefixes.length) {
        throw const FormatException('Invalid NDEF URI identifier');
      }
      uri = _uriPrefixes[payload[0]] + utf8.decode(payload.sublist(1));
    }
    records.add((
      tnf: tnf,
      type: type,
      id: id,
      payloadLength: size,
      text: text,
      language: language,
      uri: uri,
    ));
    if (end != (offset == message.length)) {
      throw const FormatException('Inconsistent NDEF message end');
    }
  }
  return records;
}
