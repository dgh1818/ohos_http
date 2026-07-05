import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohos_http/src/request_id_generator.dart';

const int _timeBits = 42;
const int _timeMask = (1 << _timeBits) - 1;
const int _maxRequestId = 1 << 62;

void main() {
  test('initial request id uses the current isolate prefix', () {
    final requestId = createOhosHttpInitialRequestId();
    final isolatePrefix = (Isolate.current.hashCode & 0xFFFFF) << _timeBits;

    expect(requestId, greaterThan(0));
    expect(requestId, lessThan(_maxRequestId));
    expect(requestId & ~_timeMask, isolatePrefix);
    expect(requestId & _timeMask, greaterThan(0));
  });

  test(
    'initial request id is not a process-global constant across isolates',
    () async {
      final requestIds = <int>{createOhosHttpInitialRequestId()};

      for (var index = 0; index < 4; index++) {
        requestIds.add(await _spawnRequestId());
      }

      expect(requestIds.length, greaterThan(1));
      for (final requestId in requestIds) {
        expect(requestId, greaterThan(0));
        expect(requestId, lessThan(_maxRequestId));
      }
    },
  );
}

Future<int> _spawnRequestId() async {
  final port = ReceivePort();
  try {
    await Isolate.spawn(_sendRequestId, port.sendPort);
    return await port.first as int;
  } finally {
    port.close();
  }
}

void _sendRequestId(SendPort port) {
  port.send(createOhosHttpInitialRequestId());
}
