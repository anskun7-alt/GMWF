// Used where dart:ffi does not exist (the web build). There are no native readings there,
// so [WinNative.instance] is always null and SystemMetricsService reports "n/a".

class WinNative {
  WinNative._();

  static WinNative? get instance => null;

  double? cpuBusyFraction() => null;
  ({int totalBytes, int availBytes})? memory() => null;
  ({int totalBytes, int freeBytes})? disk(String root) => null;
}
