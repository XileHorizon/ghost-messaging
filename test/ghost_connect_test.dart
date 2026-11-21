import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/ghost_connect.dart';
import 'package:ghost_messaging/inbox/account_helper.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/ui/ghost_connect.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart' show loadSheet;

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

class PendingHelper implements HelperLink {
  final asked = <Map<String, Object?>>[];
  final _heard = StreamController<Map<String, Object?>>.broadcast();
  final signIn = Completer<Map<String, Object?>>();

  @override
  Stream<Map<String, Object?>> get heard => _heard.stream;

  @override
  void say(Map<String, Object?> line) {
    asked.add(line);
    final id = line['id'];
    if (line['op'] == 'sign_in') {
      unawaited(
        signIn.future.then((result) {
          _heard.add({'id': id, 'ok': true, 'result': result});
        }),
      );
      return;
    }
    scheduleMicrotask(() {
      _heard.add({
        'id': id,
        'ok': true,
        'result': line['op'] == 'status' ? {'linked': false} : const [],
      });
    });
  }

  @override
  Future<void> close() async => _heard.close();
}

Future<void> pumpGhostApp(
  WidgetTester tester,
  GlobalKey<NavigatorState> navigator,
  AppState state,
) async {
  final sheet = await loadSheet(tester);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: WidgetsApp(
        navigatorKey: navigator,
        color: const Color(0xFF4F5BD5),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
        builder: (context, child) => GlacierTheme(
          sheet: sheet,
          attrs: ghostAttrs(state, 'desktop'),
          child: InkOverrides(child: GlacierToastProvider(child: child!)),
        ),
        home: const Text('Ghost home'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  GhostConnectUi.instance.navigateWith(navigator);
}

AccountHelper installInstagram(
  PendingHelper helper,
  AppState state,
  String folder,
) {
  final network = AccountHelper(
    instagramService,
    link: () async => helper,
    folder: folder,
  )..listStore = state;
  Inbox.instance = Inbox.of([network]);
  return network;
}

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
        deliver: (_, _, _) async => null,
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
      deliver: (_, _, _) async => null,
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
      deliver: (_, _, _) async => null,
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
      deliver: (_, _, _) async => 'no',
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
        Future<void> cancelled,
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
      deliver: (_, _, _) async => null,
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

  test('closing the socket cancels an unfinished delivery', () async {
    final handedOff = Completer<void>();
    final cancelledSeen = Completer<void>();
    final protocol = GhostConnectProtocol(
      store: MemoryBrowsers(),
      deliver: (_, cookies, cancelled) async {
        expect(cookies['sessionid'], 'secret');
        handedOff.complete();
        await cancelled;
        cancelledSeen.complete();
        return null;
      },
      deviceName: 'Test',
      randomBytes: fixedBytes,
    );
    final token = await pair(protocol);
    final server = GhostConnectServer(protocol, port: 0, log: (_) {});
    expect(await server.start(), isTrue);
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/ghost-extension',
      headers: {'origin': 'chrome-extension://abcdef'},
    );
    try {
      socket.add(jsonEncode({
        'id': 8,
        'op': 'deliver',
        'token': token,
        'service': 'instagram',
        'target': 'desktop',
        'cookies': {'sessionid': 'secret'},
      }));
      await handedOff.future.timeout(const Duration(seconds: 2));
      await socket.close();
      await cancelledSeen.future.timeout(const Duration(seconds: 2));
    } finally {
      await server.close();
    }
  });

  testWidgets(
    'disconnect before consent cancels and removes the warning route',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('ghost-connect-ui');
      final helper = PendingHelper();
      final state = AppState();
      final network = installInstagram(helper, state, dir.path);
      addTearDown(() async {
        network.dispose();
        Inbox.instance = null;
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final navigator = GlobalKey<NavigatorState>();
      await pumpGhostApp(tester, navigator, state);
      final disconnected = Completer<void>();

      final delivery = GhostConnectUi.instance.deliver('instagram', {
        'sessionid': 's',
        'csrftoken': 'c',
        'ds_user_id': '42',
      }, disconnected.future);
      await tester.pumpAndSettle();
      expect(find.text('Sign in to Instagram'), findsOneWidget);

      disconnected.complete();
      await tester.pumpAndSettle();
      expect(await delivery, isNull);
      expect(find.text('Sign in to Instagram'), findsNothing);
      expect(find.text('Ghost home'), findsOneWidget);
    },
  );

  testWidgets('cookies are cleared as soon as helper handoff starts', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ghost-connect-ui');
    final helper = PendingHelper();
    final state = AppState();
    final network = installInstagram(helper, state, dir.path);
    addTearDown(() async {
      if (!helper.signIn.isCompleted) {
        helper.signIn.complete({
          'me': '42',
          'name': 'Ghost',
          'handle': 'ghost',
        });
      }
      network.dispose();
      Inbox.instance = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final navigator = GlobalKey<NavigatorState>();
    await pumpGhostApp(tester, navigator, state);
    final cookies = {'sessionid': 's', 'csrftoken': 'c', 'ds_user_id': '42'};
    final delivery = GhostConnectUi.instance.deliver(
      'instagram',
      cookies,
      Completer<void>().future,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('I understand, sign in to Instagram'));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(helper.asked.where((line) => line['op'] == 'sign_in'), hasLength(1));
    expect(cookies, isEmpty);

    helper.signIn.complete({'me': '42', 'name': 'Ghost', 'handle': 'ghost'});
    await tester.pumpAndSettle();
    expect(await delivery, '@ghost');
    network.flush();
  });

  testWidgets('back navigation cannot pop while helper sign-in is busy', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ghost-connect-ui');
    final helper = PendingHelper();
    final state = AppState();
    final network = installInstagram(helper, state, dir.path);
    addTearDown(() async {
      if (!helper.signIn.isCompleted) {
        helper.signIn.complete({
          'me': '42',
          'name': 'Ghost',
          'handle': 'ghost',
        });
      }
      network.dispose();
      Inbox.instance = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final navigator = GlobalKey<NavigatorState>();
    await pumpGhostApp(tester, navigator, state);
    final delivery = GhostConnectUi.instance.deliver('instagram', {
      'sessionid': 's',
      'csrftoken': 'c',
      'ds_user_id': '42',
    }, Completer<void>().future);
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand, sign in to Instagram'));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(find.text('Signing in…'), findsOneWidget);

    await navigator.currentState!.maybePop();
    await tester.pump();
    expect(find.text('Sign in to Instagram'), findsOneWidget);
    expect(find.text('Ghost home'), findsNothing);

    helper.signIn.complete({'me': '42', 'name': 'Ghost', 'handle': 'ghost'});
    await tester.pumpAndSettle();
    expect(await delivery, '@ghost');
    expect(find.text('Ghost home'), findsOneWidget);
    network.flush();
  });

  test('phone delivery gives the not-yet message', () async {
    final protocol = GhostConnectProtocol(
      store: MemoryBrowsers(),
      deliver: (_, _, _) async => 'no',
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
