// Concept Informatique (app client) : la fenêtre de connexion RustDesk est remplacée par deux vues.
//
// - Demande de connexion : une carte au centre de l'écran (« Le technicien Jarod souhaiterait prendre
//   le contrôle… »), Autoriser (avec élévation UAC quand Windows la propose) ou Refuser. Sans réponse,
//   la demande est refusée au bout de 45 s.
// - Pendant la session : un petit overlay en haut de l'écran (technicien, temps, coût seulement en
//   dépassement) et « Demander la fin de l'accès ». Le client ne coupe pas d'un clic (fausse
//   manœuvre) : le technicien est prévenu et l'app coupe d'elle-même 2 min plus tard, ou plus tôt si
//   le technicien termine. Un message du technicien ouvre la discussion RustDesk sous l'overlay.
//
// La fenêtre RustDesk d'origine reste montée, invisible (discussion, onglets). Toute la fenêtre est
// exclue de la capture et ignore les clics envoyés par le technicien (src/ci_overlay.rs) : seul le
// client la voit et peut s'en servir.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/chat_page.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/ci_client_home.dart';
import 'package:flutter_hbb/desktop/pages/ci_reconnect.dart';
import 'package:flutter_hbb/desktop/pages/ci_session_counter.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';

const _kRequestSize = Size(500, 540);
const _kOverlaySize = Size(340, 118);
const _kConfirmSize = Size(340, 190);
const _kChatSize = Size(360, 560);
const _kRequestTimeout = 45;
const _kEndDelay = Duration(seconds: 120);

const _kNight = Color(0xF00B1220);
const _kNightLine = Color(0x595EEAD4);
const _kSoft = Color(0xFFCBD5E1);
const _kDim = Color(0xFF94A3B8);
const _kAmber = Color(0xFFFBBF24);

class CiCmShell extends StatefulWidget {
  final Widget child;
  const CiCmShell({Key? key, required this.child}) : super(key: key);

  @override
  State<CiCmShell> createState() => _CiCmShellState();
}

class _CiCmShellState extends State<CiCmShell> {
  final _alwaysObserved = 0.obs; // Obx exige au moins une valeur observée à chaque construction
  Size? _size;
  Alignment? _align;
  bool _chat = false;
  bool _closing = false;
  String _techName = '';

  void _apply(Size size, Alignment align) {
    if (_size == size && _align == align) return;
    _size = size;
    _align = align;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.setSizeAlignment(size, align);
      await windowManager.setAlwaysOnTop(true);
    });
  }

  /// Prénom du technicien pour le halo de son pointeur (src/ci_overlay.rs) ; vide hors session.
  void _shareTechName(String name) {
    if (name == _techName) return;
    _techName = name;
    bind.mainSetLocalOption(key: 'ci-tech-name', value: name);
  }

  void _closeWhenAllGone(ServerModel model) {
    if (_closing || model.clients.isEmpty) return;
    _closing = true;
    Future.delayed(const Duration(seconds: 2), () async {
      for (final c in model.clients.where((c) => c.disconnected).toList()) {
        await bind.cmRemoveDisconnectedConnection(connId: c.id);
      }
      if (await bind.cmGetClientsLength() == 0) {
        windowManager.close();
      } else {
        _closing = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ServerModel>(
        builder: (context, model, _) => Obx(() {
              _alwaysObserved.value;
              final unread = model.clients
                  .fold<int>(0, (n, c) => n + c.unreadChatMessageCount.value);
              final pending = model.clients
                  .firstWhereOrNull((c) => !c.authorized && !c.disconnected);
              final active = model.clients
                  .where((c) => c.authorized && !c.disconnected)
                  .toList();
              final Widget view;
              if (pending != null) {
                _apply(_kRequestSize, Alignment.center);
                view = _CiRequestCard(
                    key: ValueKey('request-${pending.id}'), client: pending);
              } else if (active.isNotEmpty) {
                final client = active.firstWhereOrNull(
                        (c) => c.type_() == ClientType.remote) ??
                    active.first;
                if (unread > 0) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    for (final c in model.clients) {
                      c.unreadChatMessageCount.value = 0;
                    }
                    if (!mounted) return;
                    gFFI.chatModel
                        .changeCurrentKey(MessageKey(client.peerId, client.id));
                    if (!_chat) setState(() => _chat = true);
                  });
                }
                view = _CiSessionOverlay(
                  key: ValueKey('session-${client.id}'),
                  client: client,
                  active: active,
                  chatOpen: _chat,
                  onChat: () {
                    gFFI.chatModel
                        .changeCurrentKey(MessageKey(client.peerId, client.id));
                    setState(() => _chat = !_chat);
                  },
                  onSize: (size) => _apply(size, Alignment.topCenter),
                  onTechName: _shareTechName,
                );
              } else {
                _shareTechName('');
                _closeWhenAllGone(model);
                view = const ColoredBox(color: _kNight);
              }
              // expand : sinon la pile prend la taille de la fenêtre RustDesk masquée (0×0) et rien ne s'affiche
              return Stack(fit: StackFit.expand, children: [
                Offstage(child: widget.child),
                Positioned.fill(child: view),
              ]);
            }));
  }

  @override
  void dispose() {
    _shareTechName('');
    super.dispose();
  }
}

// ---------------------------------------------------------------- demande de connexion

Future<Map<String, dynamic>?> _verify(String peerId) async {
  try {
    final res = await CiDeviceApi.get(
        '/api/v1/device/verify?peer=${Uri.encodeQueryComponent(peerId)}');
    if (res.statusCode != 200) return null;
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

class _CiRequestCard extends StatefulWidget {
  final Client client;
  const _CiRequestCard({Key? key, required this.client}) : super(key: key);

  @override
  State<_CiRequestCard> createState() => _CiRequestCardState();
}

class _CiRequestCardState extends State<_CiRequestCard> {
  late final Future<Map<String, dynamic>?> _check = _verify(widget.client.peerId);
  Timer? _timer;
  int _left = _kRequestTimeout;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) {
        _timer?.cancel();
        if (!widget.client.authorized && !widget.client.disconnected) {
          bind.cmCloseConnection(connId: widget.client.id);
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _accept(ServerModel model, bool elevate) {
    _timer?.cancel();
    model.sendLoginResponse(widget.client, true);
    if (elevate) {
      model.setShowElevation(false);
      bind.cmElevatePortable(connId: widget.client.id);
    }
  }

  void _refuse() {
    _timer?.cancel();
    bind.cmCloseConnection(connId: widget.client.id);
  }

  @override
  Widget build(BuildContext context) {
    final model = Provider.of<ServerModel>(context);
    final client = widget.client;
    final remote = client.type_() == ClientType.remote;
    final elevate = remote &&
        bind.cmCanElevate() &&
        model.showElevation &&
        bind.mainGetBuildinOption(key: kOptionHideElevateButtonInAcceptWindow) !=
            'Y';
    final canAccept = model.approveMode != 'password';
    return Theme(
      data: ciTheme(),
      child: Material(
        color: Colors.white,
        child: FutureBuilder<Map<String, dynamic>?>(
          future: _check,
          builder: (context, snap) {
            final done = snap.connectionState == ConnectionState.done;
            final verified = snap.data?['verified'] == true;
            final name = verified ? (snap.data?['name'] as String? ?? '') : '';
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
                decoration: const BoxDecoration(
                    color: kCiBg, border: Border(bottom: BorderSide(color: kCiLine))),
                child: Row(children: [
                  const _CiMark(size: 34),
                  const SizedBox(width: 12),
                  const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Concept Informatique',
                        style: TextStyle(color: kCiInk, fontSize: 15, fontWeight: FontWeight.w700)),
                    Text('Assistance à distance', style: TextStyle(color: kCiMuted, fontSize: 12.5)),
                  ]),
                ]),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(26, 20, 26, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    CiReconnectAccept(client: client),
                    Row(children: [
                      Container(
                        width: 52,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: verified ? const Color(0xFFE6F6F4) : const Color(0xFFF1F5F9),
                            shape: BoxShape.circle),
                        child: Text(
                            (name.isNotEmpty ? name : client.name).characters.firstOrNull?.toUpperCase() ?? '?',
                            style: TextStyle(
                                color: verified ? kCiBrandDark : kCiMuted,
                                fontSize: 22,
                                fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(verified && name.isNotEmpty ? 'Le technicien $name' : 'Le poste « ${client.name} »',
                              style: const TextStyle(color: kCiInk, fontSize: 19, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          if (!done)
                            const Text('Vérification du technicien…',
                                style: TextStyle(color: kCiMuted, fontSize: 12.5))
                          else if (verified)
                            const Row(children: [
                              Icon(Icons.verified_user, size: 15, color: Color(0xFF15803D)),
                              SizedBox(width: 5),
                              Text('Technicien vérifié — Concept Informatique',
                                  style: TextStyle(
                                      color: Color(0xFF15803D), fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ]),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    Text(
                        remote
                            ? 'souhaiterait prendre le contrôle de votre ordinateur pour résoudre votre souci.'
                            : 'souhaiterait accéder aux fichiers de votre ordinateur.',
                        style: const TextStyle(color: kCiInk, fontSize: 16, height: 1.45)),
                    const SizedBox(height: 14),
                    if (done && !verified)
                      _notice(
                          Icons.gpp_bad,
                          const Color(0xFFB91C1C),
                          const Color(0xFFFEF2F2),
                          snap.data == null
                              ? 'Vérification impossible. En cas de doute, refusez et appelez-nous au $kCiShopPhone.'
                              : "Ce n'est PAS un technicien Concept Informatique. Si quelqu'un vous a appelé pour "
                                  "vous demander d'accepter, refusez et appelez-nous au $kCiShopPhone.")
                    else if (remote)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            border: Border.all(color: kCiLine),
                            borderRadius: BorderRadius.circular(10)),
                        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _InfoLine(Icons.timer_outlined,
                              'Vous verrez le temps et le coût en direct en haut de l\'écran.'),
                          SizedBox(height: 6),
                          _InfoLine(Icons.close, 'Vous pouvez demander la fin de l\'accès à tout moment.'),
                        ]),
                      ),
                  ]),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 10, 26, 6),
                child: Row(children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        onPressed: _refuse,
                        style: OutlinedButton.styleFrom(
                            foregroundColor: kCiInk,
                            side: const BorderSide(color: Color(0xFFCBD5E1)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                        child: const Text('Refuser', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                  if (canAccept) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 7,
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: () => _accept(model, elevate),
                          icon: Icon(elevate ? Icons.admin_panel_settings : Icons.check, size: 20),
                          label: const Text('Autoriser',
                              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: verified ? const Color(0xFF03776C) : const Color(0xFF64748B),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                        ),
                      ),
                    ),
                  ],
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 4, 26, 16),
                child: Text(
                    [
                      if (elevate && canAccept)
                        'Windows vous demandera ensuite une confirmation : cliquez sur Oui.',
                      'Sans réponse, la demande expire dans ${ciClock(_left.clamp(0, _kRequestTimeout))}.',
                    ].join('\n'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kCiMuted, fontSize: 12.5, height: 1.4)),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _notice(IconData icon, Color fg, Color bg, String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: bg, border: Border.all(color: fg.withOpacity(0.4)), borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: fg, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: fg, fontSize: 13, height: 1.4))),
        ]),
      );
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoLine(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: kCiBrandDark),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(color: Color(0xFF334155), fontSize: 13.5))),
      ]);
}

class _CiMark extends StatelessWidget {
  final double size;
  const _CiMark({required this.size});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: kCiBrandDark, borderRadius: BorderRadius.circular(size * 0.26)),
        child: Text('CI',
            style: TextStyle(color: Colors.white, fontSize: size * 0.42, fontWeight: FontWeight.w800)),
      );
}

// ---------------------------------------------------------------- overlay pendant la session

class _CiSessionOverlay extends StatefulWidget {
  final Client client;
  final List<Client> active;
  final bool chatOpen;
  final VoidCallback onChat;
  final ValueChanged<Size> onSize;
  final ValueChanged<String> onTechName;

  const _CiSessionOverlay(
      {Key? key,
      required this.client,
      required this.active,
      required this.chatOpen,
      required this.onChat,
      required this.onSize,
      required this.onTechName})
      : super(key: key);

  @override
  State<_CiSessionOverlay> createState() => _CiSessionOverlayState();
}

class _CiSessionOverlayState extends State<_CiSessionOverlay> with CiCounterPoller<_CiSessionOverlay> {
  bool _confirm = false;
  DateTime? _localDeadline;
  bool _cancelled = false;
  Timer? _guard;
  String _verifiedName = '';

  @override
  void initState() {
    super.initState();
    startPolling();
    _verify(widget.client.peerId).then((d) {
      if (mounted && d?['verified'] == true) setState(() => _verifiedName = d?['name'] as String? ?? '');
    });
    _guard = Timer.periodic(const Duration(seconds: 1), (_) => _checkDeadline());
  }

  @override
  void dispose() {
    _guard?.cancel();
    super.dispose();
  }

  @override
  Future<http.Response> request() => CiDeviceApi.get('/api/v1/device/counter');

  /// Échéance de la coupure : celle du serveur (prolongation du technicien), sinon celle notée ici
  /// (serveur injoignable : la demande du client est tenue quand même).
  DateTime? get _deadline {
    if (_cancelled) return null;
    return data?.endDeadline ?? _localDeadline;
  }

  void _checkDeadline() {
    final d = _deadline;
    if (d == null || DateTime.now().isBefore(d)) return;
    _guard?.cancel();
    for (final c in widget.active) {
      bind.cmCloseConnection(connId: c.id);
    }
  }

  Future<void> _requestEnd(bool cancel) async {
    setState(() {
      _confirm = false;
      _cancelled = cancel;
      _localDeadline = cancel ? null : DateTime.now().add(_kEndDelay);
    });
    try {
      await CiDeviceApi.post('/api/v1/device/end', {'cancel': cancel});
    } catch (_) {}
    if (!mounted) return;
    if (cancel) _cancelled = false; // le serveur n'a plus de demande ; une nouvelle reste possible
    await reload();
  }

  String get _techName {
    final n = data?.peerName ?? '';
    return n.isNotEmpty ? n : _verifiedName;
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final deadline = _deadline;
    widget.onTechName(_techName);
    widget.onSize(widget.chatOpen ? _kChatSize : (_confirm ? _kConfirmSize : _kOverlaySize));
    final tech = _techName.isNotEmpty ? _techName : 'votre technicien';
    final over = d != null && d.active && d.balance > 0;
    final timeColor = over ? _kAmber : Colors.white;

    final Widget bottom;
    if (deadline != null) {
      final left = deadline.difference(DateTime.now()).inSeconds.clamp(0, 600);
      bottom = _bar(
          const Color(0x24FBBF24),
          const Color(0x73FBBF24),
          Row(children: [
            Expanded(
              child: Text(
                  d?.endExtended == true
                      ? '$tech termine · fin dans ${ciClock(left)}'
                      : 'Demande envoyée · fin auto dans ${ciClock(left)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFFDE68A), fontSize: 12)),
            ),
            InkWell(
              onTap: () => _requestEnd(true),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text('Annuler',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: Colors.white)),
              ),
            ),
          ]));
    } else if (_confirm) {
      bottom = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Demander à $tech de mettre fin à l\'accès ?',
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Il termine ce qu\'il fait puis se déconnecte. Sans réponse, l\'accès se coupe seul au bout de 2 min.',
            style: const TextStyle(color: _kSoft, fontSize: 11.5, height: 1.35)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _button('Non, continuer', Colors.transparent, const Color(0xFF334155), Colors.white,
              () => setState(() => _confirm = false))),
          const SizedBox(width: 8),
          Expanded(child: _button('Oui, demander', const Color(0xFFDC2626), const Color(0xFFDC2626), Colors.white,
              () => _requestEnd(false))),
        ]),
      ]);
    } else {
      bottom = _button('Demander la fin de l\'accès', const Color(0x24DC2626), const Color(0x80F87171),
          const Color(0xFFFECACA), () => setState(() => _confirm = true));
    }

    final overlay = Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const _CiMark(size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(
                    text: 'Concept Informatique', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const TextSpan(text: ' · accès par '),
                TextSpan(text: tech, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ]),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _kSoft, fontSize: 12),
            ),
          ),
          if (d != null && d.active && d.freeLeft > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration:
                  BoxDecoration(color: const Color(0x597C3AED), borderRadius: BorderRadius.circular(999)),
              child: Text('Offert ${ciClock(d.freeLeft)}',
                  style: const TextStyle(
                      color: Color(0xFFE9D5FF),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          Tooltip(
            message: widget.chatOpen ? 'Fermer la discussion' : 'Discussion avec $tech',
            child: InkWell(
              onTap: widget.onChat,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(widget.chatOpen ? Icons.expand_less : Icons.chat_bubble_outline,
                    size: 16, color: _kSoft),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        SizedBox(
          height: 34,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: d == null || !d.active
                  ? [Text(error ?? 'Compteur…', style: const TextStyle(color: _kDim, fontSize: 13))]
                  : [
                      Text(ciSigned(d.balance), style: _big(timeColor)),
                      if (over && d.rate > 0) ...[
                        const Text('  |  ', style: TextStyle(color: Color(0xFF64748B), fontSize: 20)),
                        Text(ciEuros(d.overPrice), style: _big(_kAmber)),
                      ],
                      const SizedBox(width: 10),
                      Text(
                          d.credit == null
                              ? 'temps de la session'
                              : over
                                  ? (d.rate > 0 ? '${ciEuros(d.rate)}/h' : 'hors crédit')
                                  : 'crédit restant',
                          style: const TextStyle(color: _kDim, fontSize: 11)),
                    ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        bottom,
      ]),
    );

    return Material(
      color: _kNight,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: _kNightLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          overlay,
          if (widget.chatOpen)
            Expanded(
              child: Theme(
                data: ciTheme(),
                child: Container(color: Colors.white, child: ChatPage(type: ChatPageType.desktopCM)),
              ),
            ),
        ]),
      ),
    );
  }

  TextStyle _big(Color c) => TextStyle(
      color: c, fontSize: 26, fontWeight: FontWeight.w800, height: 1.1, fontFeatures: const [FontFeature.tabularFigures()]);

  Widget _bar(Color bg, Color line, Widget child) => Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: bg, border: Border.all(color: line), borderRadius: BorderRadius.circular(8)),
        child: child,
      );

  Widget _button(String text, Color bg, Color line, Color fg, VoidCallback onTap) => SizedBox(
        height: 28,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
              backgroundColor: bg,
              foregroundColor: fg,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: line))),
          child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      );
}
