import 'dart:typed_data';
import 'package:chameleonultragui/helpers/cpu_security.dart';

const cpuFilesystemCapacity = 3252;
const _magic = [0x43, 0x46, 0x53, 0x31];

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
Uint8List _bytes(Object? text) {
  if (text == null) return Uint8List(0);
  if (text is! String) throw const FormatException('文件内容应为十六进制字符串');
  final value = text.replaceAll(RegExp(r'\s'), '');
  if (value.length.isOdd || value.length > 6504 || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(value)) {
    throw const FormatException('文件内容应为完整的十六进制字节');
  }
  return Uint8List.fromList([for (var i = 0; i < value.length; i += 2) int.parse(value.substring(i, i + 2), radix: 16)]);
}
int _integer(Object? value, int fallback) {
  if (value == null) return fallback;
  if (value is! int) throw const FormatException('文件索引和长度应为整数');
  return value;
}

class CpuFileNode {
  final int parent, type, fid, sfi, access, recordLength;
  final Uint8List aid, fci, data;
  CpuFileNode({required this.parent, required this.type, required this.fid,
    this.sfi = 0, this.access = 0, this.recordLength = 0,
    List<int> aid = const [], List<int> fci = const [], List<int> data = const []})
    : aid = Uint8List.fromList(aid), fci = Uint8List.fromList(fci), data = Uint8List.fromList(data);

  factory CpuFileNode.fromJson(Map<String, dynamic> value) {
    final fid = _bytes(value['fid']);
    if (fid.length != 2) throw const FormatException('FID 需要 2 字节，例如 3F00');
    final type = ['df', 'binary', 'records'].indexOf(value['type']?.toString().toLowerCase() ?? '');
    final rights = value['access'] ?? <String>[];
    if (rights is! List || rights.any((v) => !const ['read','write','read-pin','write-pin','read-key','write-key'].contains(v))) {
      throw const FormatException('access 只支持 read、write');
    }
    return CpuFileNode(parent: _integer(value['parent'], 255), type: type,
      fid: fid[0] << 8 | fid[1], sfi: _integer(value['sfi'], 0),
      access: (rights.contains('read') ? 1 : 0) | (rights.contains('write') ? 2 : 0) |
        (rights.contains('read-pin') ? 4 : 0) | (rights.contains('write-pin') ? 8 : 0) |
        (rights.contains('read-key') ? 16 : 0) | (rights.contains('write-key') ? 32 : 0),
      recordLength: _integer(value['recordLength'], 0), aid: _bytes(value['aid']),
      fci: _bytes(value['fci']), data: _bytes(value['data']));
  }

  Map<String, dynamic> toJson() => {
    'parent': parent == 255 ? null : parent, 'type': ['df','binary','records'][type],
    'fid': fid.toRadixString(16).padLeft(4, '0').toUpperCase(),
    if (sfi != 0) 'sfi': sfi,
    if (type != 0) 'access': [if (access & 1 != 0) 'read', if (access & 2 != 0) 'write',
      if (access & 4 != 0) 'read-pin', if (access & 8 != 0) 'write-pin',
      if (access & 16 != 0) 'read-key', if (access & 32 != 0) 'write-key'],
    if (aid.isNotEmpty) 'aid': _hex(aid), if (fci.isNotEmpty) 'fci': _hex(fci),
    if (type != 0) 'data': _hex(data), if (type == 2) 'recordLength': recordLength,
  };
}

class CpuFileSystem {
  final List<CpuFileNode> nodes;
  final CpuSecurity? security;
  CpuFileSystem(List<CpuFileNode> nodes, {this.security}) : nodes = List.unmodifiable(nodes);

  factory CpuFileSystem.fromJson(Map<String, dynamic> value) {
    if (value['security'] != null && value['security'] is! Map<String,dynamic>) {
      throw const FormatException('Invalid security object');
    }
    final items = value['nodes'];
    if (items is! List || items.isEmpty || items.length > 16 || items.any((v) => v is! Map<String, dynamic>)) {
      throw const FormatException('filesystem.nodes 需要文件节点数组');
    }
    final fs = CpuFileSystem([for (final item in items) CpuFileNode.fromJson(item as Map<String,dynamic>)],
      security: value['security'] == null ? null : CpuSecurity.fromJson(Map<String,dynamic>.from(value['security'] as Map)));
    fs.encode();
    return fs;
  }
  Map<String,dynamic> toJson() => {'nodes': [for (final node in nodes) node.toJson()],
    if (security != null) 'security': security!.toJson()};

  Uint8List encode() {
    if (nodes.isEmpty || nodes.length > 16) throw const FormatException('文件系统需要 1–16 个节点');
    final bytes = <int>[..._magic, security == null ? 1 : 2, nodes.length, 0, 0];
    void u16(int n) { bytes.add(n >> 8); bytes.add(n & 255); }
    final aids = <String>{};
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      if (n.type < 0 || n.type > 2 || n.fid <= 0 || n.fid > 65535 || n.fid == 0x3FFF ||
          n.sfi < 0 || n.sfi > 30 || n.access < 0 || n.access > (security == null ? 3 : 63) ||
          n.aid.length > 16 || (n.aid.isNotEmpty && n.aid.length < 5) || n.fci.length > 240 ||
          n.data.length > cpuFilesystemCapacity || n.recordLength < 0 || n.recordLength > 253) {
        throw const FormatException('文件类型、FID、SFI、访问权限或长度超出范围');
      }
      final a = n.access;
      if ((a & 20 != 0 && a & 1 == 0) || (a & 40 != 0 && a & 2 == 0) ||
          (a & 4 != 0 && a & 16 != 0) || (a & 8 != 0 && a & 32 != 0) ||
          (a & 12 != 0 && (security == null || security!.pin.isEmpty)) ||
          (a & 48 != 0 && (security == null || security!.key.isEmpty))) {
        throw const FormatException('Protected files require the corresponding configured PIN/key');
      }
      if (i == 0) {
        if (n.parent != 255 || n.fid != 0x3F00 || n.type != 0 || n.aid.isNotEmpty) {
          throw const FormatException('首节点必须是 MF 3F00，parent 为 null，type 为 df');
        }
      } else if (n.parent < 0 || n.parent >= i || nodes[n.parent].type != 0 || n.fid == 0x3F00) {
        throw const FormatException('父目录需要位于子文件前；3F00 只用于根目录');
      }
      if (n.type == 0) {
        if (n.data.isNotEmpty || n.recordLength != 0 || n.sfi != 0 || n.access != 0) {
          throw const FormatException('DF 目录只容纳子节点，不设置数据、SFI 或访问权限');
        }
      } else if (n.aid.isNotEmpty || (n.type == 1 && n.recordLength != 0) ||
          (n.type == 2 && (n.recordLength == 0 || n.data.length % n.recordLength != 0 || n.data.length ~/ n.recordLength > 254))) {
        throw const FormatException('EF 的数据长度、记录长度或 AID 设置无效');
      }
      for (final other in nodes.take(i)) {
        if (other.parent == n.parent && (other.fid == n.fid || (n.sfi != 0 && other.sfi == n.sfi))) {
          throw const FormatException('同目录下的 FID 和非零 SFI 需要唯一');
        }
      }
      if (n.aid.isNotEmpty && !aids.add(_hex(n.aid))) throw const FormatException('AID 需要唯一');
      bytes.addAll([n.parent, n.type]); u16(n.fid);
      bytes.addAll([n.sfi, n.access, n.aid.length]);
      u16(n.fci.length); u16(n.data.length); u16(n.recordLength);
      bytes.addAll([...n.aid,...n.fci,...n.data]);
    }
    if (security != null) bytes.addAll(security!.encode());
    if (bytes.length > cpuFilesystemCapacity) throw const FormatException('文件系统总容量上限为 3252 字节（含文件头）');
    bytes[6] = bytes.length >> 8; bytes[7] = bytes.length & 255;
    return Uint8List.fromList(bytes);
  }

  factory CpuFileSystem.decode(Uint8List bytes) {
    if (bytes.length < 8 || bytes.length > cpuFilesystemCapacity ||
        !List.generate(4,(i)=>bytes[i] == _magic[i]).every((v)=>v) ||
        ![1,2].contains(bytes[4]) || bytes[5] < 1 || bytes[5] > 16 ||
        (bytes[6] << 8 | bytes[7]) != bytes.length) throw const FormatException('CFS1 镜像头无效');
    var offset = 8;
    int u16(int p) => bytes[p] << 8 | bytes[p + 1];
    final nodes = <CpuFileNode>[];
    for (var i=0; i<bytes[5]; i++) {
      if (offset + 13 > bytes.length) throw const FormatException('CFS1 文件头被截断');
      final p = offset; final aidLength = bytes[p+6], fciLength = u16(p+7), dataLength = u16(p+9);
      offset += 13;
      if (offset + aidLength + fciLength + dataLength > bytes.length) throw const FormatException('CFS1 文件内容被截断');
      final aid = bytes.sublist(offset,offset+aidLength); offset += aidLength;
      final fci = bytes.sublist(offset,offset+fciLength); offset += fciLength;
      final data = bytes.sublist(offset,offset+dataLength); offset += dataLength;
      nodes.add(CpuFileNode(parent:bytes[p],type:bytes[p+1],fid:u16(p+2),sfi:bytes[p+4],access:bytes[p+5],recordLength:u16(p+11),aid:aid,fci:fci,data:data));
    }
    CpuSecurity? security;
    if (bytes[4] == 2) {
      if (offset + 44 != bytes.length) throw const FormatException('Truncated CFS security trailer');
      security = CpuSecurity.decode(Uint8List.fromList(bytes.sublist(offset))); offset += 44;
    }
    if (offset != bytes.length) throw const FormatException('CFS1 镜像存在额外数据');
    final fs = CpuFileSystem(nodes, security: security); fs.encode(); return fs;
  }

  factory CpuFileSystem.example() => CpuFileSystem([
    CpuFileNode(parent:255,type:0,fid:0x3F00),
    CpuFileNode(parent:0,type:0,fid:0x1001,aid:[0xF0,1,2,3,4,5,6]),
    CpuFileNode(parent:1,type:1,fid:0x1002,sfi:2,access:3,data:[0,4,0x41,0x42,0x43,0x44]),
    CpuFileNode(parent:1,type:2,fid:0x1003,sfi:4,access:3,recordLength:4,data:[1,2,3,4,5,6,7,8]),
  ]);
}

Uint8List? cpuFilesystemFromData(List<Uint8List> data) {
  if (data.length != 1 || data.first.length < 4 || !List.generate(4,(i)=>data.first[i] == _magic[i]).every((v)=>v)) return null;
  CpuFileSystem.decode(data.first);
  return data.first;
}

/// Command 6009. All image validation happens before begin/commit operations.
typedef CpuFilesystemExchange = Future<Uint8List> Function(Uint8List data);

Future<(bool, int, int)> _filesystemInfo(CpuFilesystemExchange exchange) async {
  final info = await exchange(Uint8List.fromList([0]));
  if (info.length != 6 || info[0] != 1 || info[1] > 1) throw const FormatException('文件系统协议版本或状态无效');
  final capacity = info[2] << 8 | info[3], length = info[4] << 8 | info[5];
  if (capacity < 21 || capacity > cpuFilesystemCapacity || length > capacity ||
      (info[1] == 0 && length != 0) || (info[1] == 1 && length < 21)) {
    throw const FormatException('设备返回的文件系统容量或长度无效');
  }
  return (info[1] == 1, capacity, length);
}

Future<Uint8List?> readCpuFilesystem(CpuFilesystemExchange exchange) async {
  final (active, _, length) = await _filesystemInfo(exchange);
  if (!active) return null;
  final result = BytesBuilder(copy: false);
  for (var offset = 0; offset < length; offset += 200) {
    final count = length - offset < 200 ? length - offset : 200;
    final bytes = await exchange(Uint8List.fromList([1, offset >> 8, offset & 255, count]));
    if (bytes.length != count) throw const FormatException('文件系统回读长度与请求不一致');
    result.add(bytes);
  }
  final image = result.toBytes();
  CpuFileSystem.decode(image);
  return image;
}

Future<void> writeCpuFilesystem(Uint8List image, CpuFilesystemExchange exchange) async {
  CpuFileSystem.decode(image);
  if (image[4] == 2) {
    Uint8List capabilities;
    try { capabilities = await exchange(Uint8List.fromList([7])); }
    catch (_) { throw StateError('请先升级配套认证固件：当前设备不支持 CFS v2'); }
    if (capabilities.length != 2 || capabilities[0] < 2 || capabilities[1] & 3 != 3) {
      throw StateError('请先升级配套认证固件：当前设备不支持 PIN/DES 认证');
    }
  }
  final (_, capacity, _) = await _filesystemInfo(exchange);
  if (image.length > capacity) throw const FormatException('文件镜像超过设备容量');
  try {
    await exchange(Uint8List.fromList([2, image.length >> 8, image.length & 255]));
    for (var offset = 0; offset < image.length; offset += 200) {
      final end = offset + 200 < image.length ? offset + 200 : image.length;
      await exchange(Uint8List.fromList([3, offset >> 8, offset & 255, ...image.sublist(offset, end)]));
    }
    await exchange(Uint8List.fromList([4]));
  } catch (_) {
    try { await exchange(Uint8List.fromList([5])); } catch (_) {}
    rethrow;
  }
  final actual = await readCpuFilesystem(exchange);
  if (actual == null || actual.length != image.length ||
      !List.generate(image.length, (i) => actual[i] == image[i]).every((v) => v)) {
    throw StateError('文件系统已提交，但回读校验未通过；请重新读取卡槽确认内容');
  }
}
