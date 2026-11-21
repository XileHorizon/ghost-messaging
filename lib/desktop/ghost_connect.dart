import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'store.dart';

@immutable
class GhostBrowser {
  const GhostBrowser({
    required this.name,
    required this.tokenHash,
    required this.pairedAt,
  });
  final String name;
  final String tokenHash;
  final DateTime pairedAt;
  Map<String, Object?> toJson() => {
    'name': name,
    'hash': tokenHash,
    'paired': pairedAt.millisecondsSinceEpoch,
  };
  static GhostBrowser? fromJson(Object? value) {
    if (value is! Map ||
        value['name'] is! String ||
        value['hash'] is! String ||
        value['paired'] is! num) {
      return null;
    }
    return GhostBrowser(
      name: value['name'] as String,
      tokenHash: value['hash'] as String,
      pairedAt: DateTime.fromMillisecondsSinceEpoch(
        (value['paired'] as num).toInt(),
      ),
    );
  }
}

abstract class GhostBrowserStore {
  Future<List<GhostBrowser>> load();
  Future<void> save(List<GhostBrowser> browsers);
}

class DeskGhostBrowserStore implements GhostBrowserStore {
  DeskGhostBrowserStore(this.store);
  final DeskStore store;
  static const _key = 'ghost_connect_browsers';
  @override
  Future<List<GhostBrowser>> load() async {
    try {
      final text = (await store.prefs())[_key];
      if (text == null) return [];
      return [
        for (final value in jsonDecode(text) as List)
          ?GhostBrowser.fromJson(value),
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<GhostBrowser> browsers) async {
    final prefs = await store.prefs();
    if (browsers.isEmpty) {
      prefs.remove(_key);
    } else {
      prefs[_key] = jsonEncode([
        for (final browser in browsers) browser.toJson(),
      ]);
    }
    await store.savePrefs(prefs);
  }
}

class GhostConnectError implements Exception {
  const GhostConnectError(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

typedef GhostDeliver =
    Future<String?> Function(String service, Map<String, String> cookies);

/// Ghost Connect's requests apart from the socket and screen, so security and the sign-in handoff are testable.
class GhostConnectProtocol extends ChangeNotifier {
  GhostConnectProtocol({
    required this.store,
    required this.deliver,
    required this.deviceName,
    this.appVersion = '0.11.5',
    DateTime Function()? now,
    List<int> Function(int)? randomBytes,
  }) : now = now ?? DateTime.now,
       randomBytes = randomBytes ?? _secureBytes;
  final GhostBrowserStore store;
  final GhostDeliver deliver;
  final String deviceName;
  final String appVersion;
  final DateTime Function() now;
  final List<int> Function(int) randomBytes;
  List<GhostBrowser> _browsers = [];
  List<GhostBrowser> get browsers => List.unmodifiable(_browsers);
  String? _pairHash;
  String? _pairCode;
  DateTime? _pairExpires;
  int _pairMisses = 0;
  String? get pairingCode => _pairCode;
  DateTime? get pairingExpires => _pairExpires;

  Future<void> load() async {
    _browsers = await store.load();
    notifyListeners();
  }

  String beginPairing() {
    final n = _number(randomBytes(4)) % 1000000;
    final code = n.toString().padLeft(6, '0');
    _pairCode = code;
    _pairHash = _hash(code);
    _pairExpires = now().add(const Duration(minutes: 2));
    _pairMisses = 0;
    notifyListeners();
    return code;
  }

  void closePairing() {
    _clearPairing();
    notifyListeners();
  }

  Future<void> remove(GhostBrowser browser) async {
    _browsers.removeWhere((b) => b.tokenHash == browser.tokenHash);
    await store.save(_browsers);
    notifyListeners();
  }

  Future<Object?> answer(Map<String, Object?> request) async {
    switch (request['op']) {
      case 'hello':
        final token = request['token'];
        return {
          'app': 'Ghost Messaging',
          'version': appVersion,
          'paired': token is String && _hasToken(token),
        };
      case 'pair':
        return _pair(
          '${request['code'] ?? ''}',
          '${request['name'] ?? 'Browser'}',
        );
      case 'unpair':
        final token = request['token'];
        if (token is String) {
          _browsers.removeWhere((b) => _same(b.tokenHash, _hash(token)));
          await store.save(_browsers);
          notifyListeners();
        }
        return null;
      case 'deliver':
        return _deliver(request);
      default:
        throw const GhostConnectError('Ghost doesn\'t know that request.');
    }
  }

  Future<Map<String, Object?>> _pair(String code, String name) async {
    final expected = _pairHash;
    final expires = _pairExpires;
    final valid =
        expected != null &&
        expires != null &&
        !now().isAfter(expires) &&
        _same(expected, _hash(code));
    if (!valid) {
      _pairMisses++;
      if (_pairMisses >= 5 || (expires != null && now().isAfter(expires))) {
        _clearPairing();
      }
      throw const GhostConnectError(
        'That pairing code is wrong or has expired.',
        code: 'bad_code',
      );
    }
    _clearPairing();
    final token = base64Url.encode(randomBytes(32)).replaceAll('=', '');
    _browsers.add(
      GhostBrowser(
        name: name.trim().isEmpty ? 'Browser' : name.trim(),
        tokenHash: _hash(token),
        pairedAt: now(),
      ),
    );
    await store.save(_browsers);
    notifyListeners();
    return {'token': token, 'device': deviceName};
  }

  Future<Map<String, Object?>> _deliver(Map<String, Object?> request) async {
    final token = request['token'];
    if (token is! String || !_hasToken(token)) {
      throw const GhostConnectError(
        'Pair this browser with Ghost again.',
        code: 'unpaired',
      );
    }
    if (request['target'] == 'phone') {
      throw const GhostConnectError(
        'Sending to the phone isn\'t in this version of Ghost yet.',
      );
    }
    if (request['target'] != 'desktop') {
      throw const GhostConnectError('Choose this computer or your phone.');
    }
    final service = request['service'];
    final raw = request['cookies'];
    if (service is! String ||
        !const {'messenger', 'instagram', 'linkedin'}.contains(service) ||
        raw is! Map) {
      throw const GhostConnectError('That sign-in cannot be used by Ghost.');
    }
    final cookies = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.key is String && entry.value is String) {
        cookies[entry.key as String] = entry.value as String;
      }
    }
    final account = await deliver(service, cookies);
    if (account == null) throw const GhostConnectError('Cancelled in Ghost.');
    return {'account': account, 'where': 'desktop'};
  }

  bool _hasToken(String token) {
    final hash = _hash(token);
    return _browsers.any((browser) => _same(browser.tokenHash, hash));
  }

  void _clearPairing() {
    _pairCode = null;
    _pairHash = null;
    _pairExpires = null;
    _pairMisses = 0;
  }

  static List<int> _secureBytes(int length) {
    final random = Random.secure();
    return List.generate(length, (_) => random.nextInt(256));
  }

  static int _number(List<int> bytes) {
    var value = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
    }
    return value;
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static bool _same(String a, String b) {
    if (a.isEmpty || b.isEmpty) return a.isEmpty && b.isEmpty;
    var different = a.length ^ b.length;
    final most = max(a.length, b.length);
    for (var i = 0; i < most; i++) {
      different |= a.codeUnitAt(i % a.length) ^ b.codeUnitAt(i % b.length);
    }
    return different == 0;
  }
}

/// The loopback-only WebSocket endpoint used by Ghost Connect.
class GhostConnectServer {
  GhostConnectServer(
    this.protocol, {
    this.port = 47823,
    void Function(String)? log,
  }) : log = log ?? debugPrint;
  final GhostConnectProtocol protocol;
  final int port;
  final void Function(String) log;
  HttpServer? _server;
  int? get boundPort => _server?.port;
  Future<bool> start() async {
    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
    } catch (e) {
      log('Ghost Connect could not listen on 127.0.0.1:$port: $e');
      return false;
    }
    _server!.listen(
      _request,
      onError: (Object e) => log('Ghost Connect stopped listening: $e'),
    );
    return true;
  }

  Future<void> close() async => _server?.close(force: true);
  Future<void> _request(HttpRequest request) async {
    final origin = request.headers.value('origin') ?? '';
    if (request.uri.path != '/ghost-extension' ||
        !_extensionOrigin(origin) ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((message) => _message(socket, message));
    } catch (e) {
      log('Ghost Connect refused a WebSocket: $e');
    }
  }

  Future<void> _message(WebSocket socket, Object? message) async {
    Object? id;
    try {
      final decoded = jsonDecode(
        message is String ? message : utf8.decode(message as List<int>),
      );
      if (decoded is! Map) throw const FormatException();
      final request = decoded.cast<String, Object?>();
      id = request['id'];
      final result = await protocol.answer(request);
      socket.add(jsonEncode({'id': id, 'ok': true, 'result': result}));
    } on GhostConnectError catch (e) {
      socket.add(
        jsonEncode({
          'id': id,
          'ok': false,
          'error': e.message,
          if (e.code != null) 'code': e.code,
        }),
      );
    } catch (_) {
      socket.add(
        jsonEncode({
          'id': id,
          'ok': false,
          'error': 'Ghost could not read that request.',
        }),
      );
    }
  }

  static bool _extensionOrigin(String origin) =>
      RegExp(r'^(chrome-extension|moz-extension)://[^/]+$').hasMatch(origin);
}
