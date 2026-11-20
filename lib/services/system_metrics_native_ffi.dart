// Native Windows readings (kernel32 via dart:ffi, no extra packages).
// Imported only where dart:ffi exists; the web build gets system_metrics_native_stub.dart.

import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'package:flutter/foundation.dart';

typedef _GetSystemTimesC = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _GetSystemTimesD = int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _MemStatusC = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>);
typedef _MemStatusD = int Function(ffi.Pointer<ffi.Uint8>);
typedef _DiskFreeC = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _DiskFreeD = int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _LocalAllocC = ffi.Pointer<ffi.Uint8> Function(ffi.Uint32, ffi.IntPtr);
typedef _LocalAllocD = ffi.Pointer<ffi.Uint8> Function(int, int);

class WinNative {
  static WinNative? _inst;
  static bool _tried = false;

  /// null when not on Windows or kernel32 could not be bound.
  static WinNative? get instance {
    if (_tried) return _inst;
    _tried = true;
    if (!io.Platform.isWindows) return null;
    try {
      _inst = WinNative._();
    } catch (e) {
      debugPrint('[SystemMetricsService] native metrics unavailable: $e');
      _inst = null;
    }
    return _inst;
  }

  late final _GetSystemTimesD _getSystemTimes;
  late final _MemStatusD _memStatus;
  late final _DiskFreeD _diskFree;

  /// One fixed scratch buffer (LPTR = zeroed) reused for every call, never freed.
  late final ffi.Pointer<ffi.Uint8> _buf;
  static const _offIdle = 0, _offKernel = 8, _offUser = 16;
  static const _offMem = 32; // MEMORYSTATUSEX, 64 bytes
  static const _offDisk = 96; // 3 x ULARGE_INTEGER
  static const _offPath = 128; // UTF-16 drive root, e.g. "C:\"
  static const _bufSize = 256;

  int? _prevIdle, _prevTotal;

  WinNative._() {
    final k32 = ffi.DynamicLibrary.open('kernel32.dll');
    _getSystemTimes = k32.lookupFunction<_GetSystemTimesC, _GetSystemTimesD>('GetSystemTimes');
    _memStatus = k32.lookupFunction<_MemStatusC, _MemStatusD>('GlobalMemoryStatusEx');
    _diskFree = k32.lookupFunction<_DiskFreeC, _DiskFreeD>('GetDiskFreeSpaceExW');
    final localAlloc = k32.lookupFunction<_LocalAllocC, _LocalAllocD>('LocalAlloc');
    _buf = localAlloc(0x0040 /* LPTR */, _bufSize);
    if (_buf.address == 0) throw StateError('LocalAlloc failed');
  }

  ffi.Pointer<ffi.Uint8> _at(int off) => ffi.Pointer<ffi.Uint8>.fromAddress(_buf.address + off);
  int _u64(int off) => _at(off).cast<ffi.Uint64>().value;

  /// Share of time the CPUs were busy since the previous call (null on the first call).
  double? cpuBusyFraction() {
    if (_getSystemTimes(_at(_offIdle), _at(_offKernel), _at(_offUser)) == 0) return null;
    final idle = _u64(_offIdle);
    final total = _u64(_offKernel) + _u64(_offUser); // kernel time includes idle time
    final pIdle = _prevIdle, pTotal = _prevTotal;
    _prevIdle = idle;
    _prevTotal = total;
    if (pIdle == null || pTotal == null) return null;
    final dTotal = total - pTotal;
    final dIdle = idle - pIdle;
    if (dTotal <= 0) return null;
    return ((dTotal - dIdle) / dTotal).clamp(0.0, 1.0);
  }

  ({int totalBytes, int availBytes})? memory() {
    _at(_offMem).cast<ffi.Uint32>().value = 64; // dwLength
    if (_memStatus(_at(_offMem)) == 0) return null;
    return (totalBytes: _u64(_offMem + 8), availBytes: _u64(_offMem + 16));
  }

  ({int totalBytes, int freeBytes})? disk(String root) {
    final units = root.codeUnits;
    if ((units.length + 1) * 2 > _bufSize - _offPath) return null;
    final p = _at(_offPath).cast<ffi.Uint16>();
    for (var i = 0; i < units.length; i++) {
      ffi.Pointer<ffi.Uint16>.fromAddress(p.address + i * 2).value = units[i];
    }
    ffi.Pointer<ffi.Uint16>.fromAddress(p.address + units.length * 2).value = 0;
    if (_diskFree(_at(_offPath), _at(_offDisk), _at(_offDisk + 8), _at(_offDisk + 16)) == 0) return null;
    return (totalBytes: _u64(_offDisk + 8), freeBytes: _u64(_offDisk + 16));
  }
}
