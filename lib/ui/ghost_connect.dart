import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../desktop/ghost_connect.dart';
import '../inbox/account_helper.dart';
import '../inbox/inbox.dart';
import '../kit/settings_kit.dart';
import 'common.dart';
import 'settings.dart';

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// The bridge between the loopback server and the desktop's navigator. Cookie values stay only in the pending screen.
class GhostConnectUi {
  GhostConnectUi._();
  static final instance = GhostConnectUi._();
  GhostConnectProtocol? protocol;
  GlobalKey<NavigatorState>? _navigator;
  Completer<void>? _ready;

  void navigateWith(GlobalKey<NavigatorState> navigator) {
    _navigator = navigator;
    _ready?.complete();
    _ready = null;
  }

  Future<String?> deliver(String service, Map<String, String> cookies) async {
    final network = Inbox.instance.named(service);
    if (network is! AccountHelper) {
      throw GhostConnectError(
        '${service == 'linkedin' ? 'LinkedIn' : service} isn\'t available in this build of Ghost.',
      );
    }
    while (_navigator?.currentState == null) {
      _ready ??= Completer<void>();
      await _ready!.future;
    }
    final answer = Completer<String?>();
    _navigator!.currentState!.push(
      PageRouteBuilder<void>(
        pageBuilder: (context, _, _) => GhostConnectSignIn(
          network: network,
          cookies: cookies,
          answer: answer,
        ),
      ),
    );
    return answer.future;
  }
}

void addGhostConnectSettings(GhostConnectProtocol protocol) =>
    SettingsSources.add(ghostConnectSettingsSections, watch: [protocol]);

List<SettingsSection> ghostConnectSettingsSections() => [
  SettingsSection(
    id: 'browser-extension',
    label: 'Browser extension',
    icon: _icon(Lucide.puzzle),
    hue: 'cyan',
    group: 'me',
    where: SettingsWhere.computer,
    summary: (_) {
      final count = GhostConnectUi.instance.protocol?.browsers.length ?? 0;
      return count == 0
          ? 'Pair Ghost Connect'
          : '$count paired ${count == 1 ? 'browser' : 'browsers'}';
    },
    page: (context, model) => const [GhostConnectPane()],
  ),
];

class GhostConnectPane extends StatefulWidget {
  const GhostConnectPane({super.key});
  @override
  State<GhostConnectPane> createState() => _GhostConnectPaneState();
}

class _GhostConnectPaneState extends State<GhostConnectPane> {
  Timer? _clock;
  GhostConnectProtocol get protocol => GhostConnectUi.instance.protocol!;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && protocol.pairingCode != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    protocol.closePairing();
    super.dispose();
  }

  void _pair() => setState(protocol.beginPairing);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: protocol,
    builder: (context, _) {
      final expires = protocol.pairingExpires;
      final left = expires == null
          ? 0
          : expires.difference(protocol.now()).inSeconds.clamp(0, 120);
      if (left == 0 && protocol.pairingCode != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => protocol.closePairing(),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneSection(
            title: 'Ghost Connect',
            description: const Text(
              'Pair the Ghost Connect browser extension on this computer. It can hand a new Messenger or Instagram sign-in to Ghost without copying cookies by hand.',
            ),
            children: [
              if (protocol.pairingCode == null)
                SettingRow(
                  icon: _icon(Lucide.link),
                  label: 'Pair a browser',
                  hint: const Text('The extension asks for a six-digit code.'),
                  onPress: _pair,
                )
              else
                SettingRowBox(
                  child: Padding(
                    padding: EdgeInsets.all(context.tokens.space(4)),
                    child: Column(
                      children: [
                        Text(
                          protocol.pairingCode!,
                          style: TextStyle(
                            fontFamily: 'JetBrains Mono Variable',
                            fontSize: context.tokens.fontSize('2xl'),
                            letterSpacing: 5,
                          ),
                        ),
                        SizedBox(height: context.tokens.space(2)),
                        Text(
                          'Type this in Ghost Connect · ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')} left',
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (protocol.browsers.isNotEmpty) ...[
            SizedBox(height: context.tokens.space(5)),
            PaneSection(
              title: 'Paired browsers',
              children: [
                for (final browser in protocol.browsers)
                  SettingRow(
                    icon: _icon(Lucide.puzzle),
                    label: browser.name,
                    hint: Text('Paired ${_date(browser.pairedAt)}'),
                    control: GlacierPressable(
                      onPressed: () => protocol.remove(browser),
                      semanticLabel: 'Remove ${browser.name}',
                      builder: (context, state) => Padding(
                        padding: EdgeInsets.all(context.tokens.space(2)),
                        child: const Text('Remove'),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          SizedBox(height: context.tokens.space(4)),
          const SettingsFootnote(
            child: Text(
              'Ghost keeps only a one-way hash of each browser token. Remove a browser here to stop it sending sign-ins. Pairing works only while this page and its code are open.',
            ),
          ),
        ],
      );
    },
  );

  static String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

/// The service warning remains a decision in Ghost. The socket waits for this screen to finish.
class GhostConnectSignIn extends StatefulWidget {
  const GhostConnectSignIn({
    super.key,
    required this.network,
    required this.cookies,
    required this.answer,
  });
  final AccountHelper network;
  final Map<String, String> cookies;
  final Completer<String?> answer;
  @override
  State<GhostConnectSignIn> createState() => _GhostConnectSignInState();
}

class _GhostConnectSignInState extends State<GhostConnectSignIn> {
  bool _busy = false;
  bool _finished = false;

  void _answer(String? account) {
    if (_finished) return;
    _finished = true;
    widget.answer.complete(account);
  }

  Future<void> _agree() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.network.signIn(jsonEncode(widget.cookies));
    if (!mounted) return;
    if (ok) {
      _answer(widget.network.account ?? widget.network.service.name);
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  void _cancel() {
    _answer(null);
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _answer(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.network.service;
    return GhostPage(
      title: 'Sign in to ${service.name}',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            context.tokens.space(4),
            context.tokens.space(2),
            context.tokens.space(4),
            context.tokens.space(8),
          ),
          children: [
            PaneSection(
              title: '${service.name} doesn\'t support this',
              description: const Text(
                'Ghost Connect has a browser sign-in ready. Read this before using it.',
              ),
              footer: widget.network.error == null
                  ? null
                  : Text(widget.network.error!),
              children: [
                SettingRowBox(
                  child: Padding(
                    padding: EdgeInsets.all(context.tokens.space(3)),
                    child: Text(service.warning),
                  ),
                ),
                SettingRow(
                  icon: _icon(Lucide.shieldCheck),
                  label: _busy
                      ? 'Signing in…'
                      : 'I understand, sign in to ${service.name}',
                  disabled: _busy,
                  onPress: _agree,
                ),
                SettingRow(
                  icon: _icon(Lucide.arrowLeft),
                  label: 'Not now',
                  disabled: _busy,
                  onPress: _cancel,
                ),
              ],
            ),
            SizedBox(height: context.tokens.space(4)),
            const SettingsFootnote(
              child: Text(
                'The browser sign-in is handed directly to the helper on this computer. Ghost Connect and this screen do not save it.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
