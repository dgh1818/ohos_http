import 'dart:isolate';

int createOhosHttpInitialRequestId() {
  final isolateBits = Isolate.current.hashCode & 0xFFFFF;
  final timeBits = DateTime.now().microsecondsSinceEpoch & 0x3FFFFFFFFFF;
  return (isolateBits << 42) | timeBits;
}
