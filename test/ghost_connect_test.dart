import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/ghost_connect.dart';

class MemoryBrowsers implements GhostBrowserStore {
  List<GhostBrowser> browsers = [];
  @override
  Future<List<GhostBrowser>> load() async => List.of(browsers);
  @override
  Future<void> save(List<GhostBrowser> value) async =>
      browsers = List.of(value);
}

List<int> fixedBytes(int length) =>
    length == 4 ? [0, 1, 226, 64] : List.generate(length, (i) => i);

Future<String> pair(GhostConnectProtocol protocol) async {
  protocol.beginPairing();
  final result =
      await protocol.answer({
            'op': 'pair',
            'code': '123456',
            'name': 'Chrome here',
          })
          as Map;
  return result['token'] as String;
}

void main() {
  test(
    'pairs with the right code, rejects a wrong code, and uses a code once',
    () async {
      final protocol = GhostConnectProtocol(
        store: MemoryBrowsers(),
        deliver: (_, _) async => null,
        deviceName: 'Test PC',
        randomBytes: fixedBytes,
      );
      await protocol.load();
      protocol.beginPairing();
      await expectLater(
        protocol.answer({'op': 'pair', 'code': '654321', 'name': 'Chrome'}),
        throwsA(
          isA<GhostConnectError>().having((e) => e.code, 'code', 'bad_code'),
        ),
      );
      final result =
          await protocol.answer({
                'op': 'pair',
                'code': '123456',
                'name': 'Chrome',
              })
              as Map;
      expect(result['device'], 'Test PC');
      expect((result['token'] as String).length, greaterThanOrEqualTo(43));
      await expectLater(
        protocol.answer({'op': 'pair', 'code': '123456', 'name': 'Chrome'}),
        throwsA(
          isA<GhostConnectError>().having((e) => e.code, 'code', 'bad_code'),
        ),
      );
    },
  );

  test('an expired code is rejected', () async {
    var now = DateTime(2026, 11, 21);
    final protocol = GhostConnectProtocol(
      store: MemoryBrowsers(),
      deliver: (_, _) async => null,
      deviceName: 'Test',
      now: () => now,
      randomBytes: fixedBytes,
    );
    protocol.beginPairing();
    now = now.add(const Duration(minutes: 2, seconds: 1));
    await expectLater(
      protocol.answer({'op': 'pair', 'code': '123456', 'name': 'Firefox'}),
      throwsA(
        isA<GhostConnectError>().having((e) => e.code, 'code', 'bad_code'),
      ),
    );
  });

  test('five wrong tries kill the pairing code', () async {
    final protocol = GhostConnectProtocol(
      store: MemoryBrowsers(),
      deliver: (_, _) async => null,
      deviceName: 'Test',
      randomBytes: fixedBytes,
    );
    protocol.beginPairing();
    for (var i = 0; i < 5; i++) {
      await expectLater(
        protocol.answer({'op': 'pair', 'code': '000000', 'name': 'Firefox'}),
        throwsA(isA<GhostConnectError>()),
      );
    }
    await expectLater(
      protocol.answer({'op': 'pair', 'code': '123456', 'name': 'Firefox'}),
      throwsA(
        isA<GhostConnectError>().having((e) => e.code, 'code', 'bad_code'),
      ),
    );
  });

  test('an unpaired token cannot deliver', () async {
    final protocol = GhostConnectProtocol(
      store: MemoryBrowsers(),
      deliver: (_, _) async => 'no',
      deviceName: 'Test',
    );
    await expectLater(
      protocol.answer({
        'op': 'deliver',
        'token': 'unknown',
        'service': 'instagram',
        'target': 'desktop',
        'cookies': {'sessionid': 'secret'},
      }),
      throwsA(
        isA<GhostConnectError>().having((e) => e.code, 'code', 'unpaired'),
      ),
    );
  });

  test(
    'deliver waits for agreement before routing cookies to signIn',
    () async {
      final agreed = Completer<void>();
      var signedIn = false;
      Map<String, String>? received;
      Future<String?> handoff(
        String service,
        Map<String, String> cookies,
      ) async {
        expect(service, 'instagram');
        await agreed.future;
        signedIn = true;
        received = cookies;
        return '@ghost';
      }

      final protocol = GhostConnectProtocol(
        store: MemoryBrowsers(),
        deliver: handoff,
        deviceName: 'Test',
        randomBytes: fixedBytes,
      );
      final token = await pair(protocol);
      final answer = protocol.answer({
        'op': 'deliver',
        'token': token,
        'service': 'instagram',
        'target': 'desktop',
        'cookies': {'sessionid': 'secret', 'csrftoken': 'csrf'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(signedIn, isFalse);
      agreed.complete();
      expect(await answer, {'account': '@ghost', 'where': 'desktop'});
      expect(received, {'sessionid': 'secret', 'csrftoken': 'csrf'});
    },
  );

  test('server rejects page origins and accepts extension origins', () async {
    final protocol = GhostConnectProtocol(
      store: MemoryBrowsers(),
      deliver: (_, _) async => null,
      deviceName: 'Test',
    );
    final server = GhostConnectServer(protocol, port: 0, log: (_) {});
    expect(await server.start(), isTrue);
    final url = 'ws://127.0.0.1:${server.boundPort}/ghost-extension';
    try {
      await expectLater(
        WebSocket.connect(url, headers: {'origin': 'https://evil.example'}),
        throwsA(anything),
      );
      final socket = await WebSocket.connect(
        url,
        headers: {'origin': 'chrome-extension://abcdef'},
      );
      socket.add(jsonEncode({'id': 7, 'op': 'hello', 'v': 1, 'token': null}));
      final response = jsonDecode(await socket.first as String) as Map;
      expect(response['id'], 7);
      expect(response['ok'], isTrue);
      expect((response['result'] as Map)['paired'], isFalse);
      await socket.close();
    } finally {
      await server.close();
    }
  });

  test('phone delivery gives the not-yet message', () async {
    final protocol = GhostConnectProtocol(
      store: MemoryBrowsers(),
      deliver: (_, _) async => 'no',
      deviceName: 'Test',
      randomBytes: fixedBytes,
    );
    final token = await pair(protocol);
    await expectLater(
      protocol.answer({
        'op': 'deliver',
        'token': token,
        'service': 'messenger',
        'target': 'phone',
        'cookies': {},
      }),
      throwsA(
        isA<GhostConnectError>().having(
          (e) => e.message,
          'message',
          "Sending to the phone isn't in this version of Ghost yet.",
        ),
      ),
    );
  });
}
