import 'dart:typed_data';

enum CpuDirectoryIssueKind {
  structure,
  tag,
  length,
  lengthBytes,
  value,
  indefinite,
}

typedef CpuDirectoryIssue = ({
  CpuDirectoryIssueKind kind,
  int offset,
  int? tag,
  int expected,
  int available,
});
typedef CpuDirectoryField = ({int tag, Uint8List value});
typedef CpuDirectoryInspection = ({
  List<CpuDirectoryField> fields,
  List<CpuDirectoryIssue> issues,
});

enum CpuDirectoryFormat { pseRecord, ppseInline, efDir }

/// Inspect a declared directory without trying to repair card data. Keep
/// valid fields before a bad TLV so the AID and the original bytes stay visible.
CpuDirectoryInspection inspectCpuDirectoryRecord(
  Uint8List bytes, {
  CpuDirectoryFormat format = CpuDirectoryFormat.pseRecord,
}) {
  final fields = <CpuDirectoryField>[], issues = <CpuDirectoryIssue>[];
  void issue(
    CpuDirectoryIssueKind kind,
    int offset, {
    int? tag,
    int expected = 0,
    int available = 0,
  }) => issues.add((
    kind: kind,
    offset: offset,
    tag: tag,
    expected: expected,
    available: available,
  ));

  Iterable<({int tag, int start, int end})> elements(int start, int end) sync* {
    var offset = start;
    while (offset < end) {
      final at = offset;
      final first = bytes[offset++];
      if (first == 0x00 || first == 0xFF) continue;
      var tag = first;
      if (first & 0x1F == 0x1F) {
        var complete = false;
        for (var n = 0; n < 2 && offset < end; n++) {
          final b = bytes[offset++];
          tag = tag << 8 | b;
          if (b & 0x80 == 0) {
            complete = true;
            break;
          }
        }
        if (!complete) {
          issue(CpuDirectoryIssueKind.tag, at);
          return;
        }
      }
      if (offset >= end) {
        issue(CpuDirectoryIssueKind.length, at, tag: tag);
        return;
      }
      var size = bytes[offset++];
      if (size & 0x80 != 0) {
        final count = size & 0x7F;
        if (count == 0) {
          issue(CpuDirectoryIssueKind.indefinite, at, tag: tag);
          return;
        }
        if (count > end - offset || count > 2) {
          issue(
            CpuDirectoryIssueKind.lengthBytes,
            at,
            tag: tag,
            expected: count,
            available: end - offset,
          );
          return;
        }
        size = 0;
        for (var i = 0; i < count; i++) {
          size = size << 8 | bytes[offset++];
        }
      }
      if (size > end - offset) {
        issue(
          CpuDirectoryIssueKind.value,
          at,
          tag: tag,
          expected: size,
          available: end - offset,
        );
        return;
      }
      final next = offset + size;
      yield (tag: tag, start: offset, end: next);
      offset = next;
    }
  }

  var hasTemplate = false;
  void inspectApplications(Iterable<({int tag, int start, int end})> apps) {
    for (final app in apps) {
      if (app.tag != 0x61) continue;
      hasTemplate = true;
      for (final field in elements(app.start, app.end)) {
        final extra = format == CpuDirectoryFormat.efDir ? 0x51 : 0x87;
        if ([
          0x4F,
          0x50,
          extra,
          if (format != CpuDirectoryFormat.efDir) 0x9D,
        ].contains(field.tag)) {
          fields.add((
            tag: field.tag,
            value: bytes.sublist(field.start, field.end),
          ));
        }
      }
    }
  }

  if (format == CpuDirectoryFormat.pseRecord) {
    for (final outer in elements(0, bytes.length)) {
      if (outer.tag == 0x70)
        inspectApplications(elements(outer.start, outer.end));
    }
  } else {
    inspectApplications(elements(0, bytes.length));
  }
  if (!hasTemplate && issues.isEmpty) issue(CpuDirectoryIssueKind.structure, 0);
  return (fields: fields, issues: issues);
}
