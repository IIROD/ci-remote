// Concept Informatique (app technicien) : barre d'actions en haut de la fenêtre de session.
//
// De gauche à droite : client et PC, compteur (montant seulement en dépassement), contrôle du PC
// (Partagé / Tech uniquement / Privacy), « Rendre la main 2 min », Fichiers, Discussion, Outils
// (palette avec recherche), Alimentation, Collègue ; à droite qualité d'image, plein écran, Terminer.
// Quand le client demande la fin de l'accès, le milieu de la barre devient un bandeau : Terminer
// maintenant ou « Encore 2 min » (une seule fois), avant la coupure automatique côté client.
//
// La barre RustDesk d'origine reste disponible pour les réglages avancés (écran, clavier…).
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/ci_actions.dart';
import 'package:flutter_hbb/desktop/pages/ci_session_counter.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// Hauteur réservée en haut de la page de session (le canevas la retire de sa taille).
const kCiTechBarHeight = 60.0;

const _bg = Color(0xFF111A2C);
const _ground = Color(0xFF0B1220);
const _line = Color(0xFF1E293B);
const _fg = Color(0xFFCBD5E1);
const _muted = Color(0xFF94A3B8);
const _teal = Color(0xFF0F766E);
const _amber = Color(0xFFFBBF24);
const _red = Color(0xFFDC2626);

const _kRecentOption = 'ci-recent-tools';
const _kConsole = {'cmd', 'powershell'};

class CiTechBar extends StatefulWidget implements PreferredSizeWidget {
  final String id;
  final FFI ffi;
  const CiTechBar({Key? key, required this.id, required this.ffi}) : super(key: key);

  @override
  Size get preferredSize => const Size.fromHeight(kCiTechBarHeight);

  @override
  State<CiTechBar> createState() => _CiTechBarState();
}

class _CiTechBarState extends State<CiTechBar> with CiCounterPoller<CiTechBar> {
  String _quality = '';
  bool _extending = false;

  FFI get ffi => widget.ffi;
  String get id => widget.id;
  bool get _windows => ffi.ffiModel.pi.platform == kPeerPlatformWindows;
  bool get _keyboard => ffi.ffiModel.keyboard && !ffi.ffiModel.viewOnly;

  @override
  void initState() {
    super.initState();
    startPolling();
    bind.sessionGetImageQuality(sessionId: ffi.sessionId).then((q) {
      if (mounted) setState(() => _quality = q ?? '');
    });
  }

  @override
  Future<http.Response> request() async {
    final base = (await bind.mainGetApiServer()).replaceAll(RegExp(r'/+$'), '');
    return http.get(Uri.parse('$base/api/v1/tech/counter?peer=${Uri.encodeQueryComponent(id)}'), headers: {
      'Authorization': 'Bearer ${bind.mainGetLocalOption(key: 'ci-tech-token')}',
      'X-CI-Device': await bind.mainGetMyId(),
    }).timeout(const Duration(seconds: 10));
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    return Material(
      color: _bg,
      child: Container(
        height: kCiTechBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
        child: LayoutBuilder(builder: (context, box) {
          final compact = box.maxWidth < 1280;
          final ending = d != null && d.endDeadline != null;
          return Row(children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  if (!compact || ending) _client(d),
                  _counter(d),
                  _sep(),
                  if (ending) _endBanner(d) else ..._controls(compact),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            _qualityMenu(),
            const SizedBox(width: 6),
            Obx(() => _square(
                stateGlobal.fullscreen.isTrue ? Icons.fullscreen_exit : Icons.fullscreen,
                stateGlobal.fullscreen.isTrue ? 'Quitter le plein écran' : 'Plein écran',
                () => stateGlobal.setFullscreen(stateGlobal.fullscreen.isFalse))),
            const SizedBox(width: 6),
            _filled('Terminer', _red, () => closeConnection(id: id)),
          ]);
        }),
      ),
    );
  }

  // ---------------------------------------------------------------- blocs

  Widget _client(CiCounterData? d) {
    final name = (d?.client ?? '').isNotEmpty ? d!.client! : (ffi.ffiModel.pi.hostname);
    final host = d?.hostname ?? ffi.ffiModel.pi.hostname;
    final connected = d != null && d.active ? ' · connecté ${ciClock(d.secondsNow)}' : '';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 230),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: const Color(0xFF134E4A),
          child: Text(name.characters.firstOrNull?.toUpperCase() ?? '?',
              style: const TextStyle(color: Color(0xFF5EEAD4), fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700)),
            Text('$host$connected',
                overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 11.5)),
          ]),
        ),
        const SizedBox(width: 10),
      ]),
    );
  }

  Widget _counter(CiCounterData? d) {
    final List<Widget> parts;
    String tip;
    if (d == null || !d.active) {
      parts = [Text(error ?? 'Compteur…', style: const TextStyle(color: _muted, fontSize: 12))];
      tip = error ?? 'En attente du serveur d\'assistance';
    } else {
      final over = d.balance > 0;
      final color = over ? _amber : Colors.white;
      parts = d.freeLeft > 0
          ? [
              // Minutes offertes : décomptées en grand, en violet, avant le crédit
              Text(ciClock(d.freeLeft), style: _num(const Color(0xFFC4B5FD))),
              const SizedBox(width: 7),
              const Text('offertes',
                  style: TextStyle(color: Color(0xFFC4B5FD), fontSize: 12, fontWeight: FontWeight.w600)),
            ]
          : [
              Text(ciSigned(d.balance), style: _num(color)),
              if (over && d.rate > 0) ...[
                const Text('  |  ', style: TextStyle(color: Color(0xFF475569))),
                Text(ciEuros(d.overPrice), style: _num(_amber)),
              ],
            ];
      tip = [
        if (d.credit == null) 'PC non rattaché à un compte client',
        'Temps connecté : ${ciClock(d.secondsNow)}',
        if (d.freeSeconds > 0) '${d.freeSeconds ~/ 60} min offertes au début',
        if (d.credit != null) 'Crédit au début de la session : ${d.credit! < 0 ? '-' : ''}${ciClock(d.credit!)}',
        if (d.rate > 0) 'Dépassement : ${ciEuros(d.rate)} / h (affiché seulement)',
      ].join('\n');
    }
    return Tooltip(
      message: tip,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration:
            BoxDecoration(color: _ground, border: Border.all(color: _line), borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: parts),
      ),
    );
  }

  List<Widget> _controls(bool compact) => [
        _mode(compact),
        const SizedBox(width: 8),
        Obx(() => _outlined(Icons.replay, 'Rendre la main 2 min',
            BlockInputState.find(id).value ? () => CiTechMode.giveBack(ffi, const Duration(minutes: 2)) : null,
            compact: compact)),
        _sep(),
        _tool(Icons.drive_file_move_outlined, 'Fichiers', _files),
        _tool(Icons.chat_bubble_outline, 'Discussion', _chat),
        if (_keyboard && _windows) _tool(Icons.handyman_outlined, 'Outils', _palette),
        _powerMenu(),
        _tool(Icons.switch_account_outlined, 'Collègue', () => ciHandoffDialog(ffi)),
      ];

  Widget _mode(bool compact) => Obx(() {
        final block = BlockInputState.find(id).value;
        final privacyState = PrivacyModeState.find(id);
        final privacyOn = privacyState.value.isNotEmpty;
        final toggles = toolbarPrivacyMode(privacyState, context, id, ffi);
        final privacy = toggles.isEmpty ? null : toggles.first.onChanged;
        final canBlock = _windows && ffi.ffiModel.keyboard && ffi.ffiModel.permissions['block_input'] != false;
        final mode = privacyOn ? 2 : (block ? 1 : 0);

        Future<void> select(int v) async {
          if (v == mode) return;
          if (mode == 2) {
            ciLog(ffi, 'privacy', 'Privacy désactivée');
            privacy?.call(false);
          }
          if (v == 0 && block) await CiTechMode.set(ffi, false);
          if (v == 1 && !block) await CiTechMode.set(ffi, true);
          if (v == 2) {
            ciLog(ffi, 'privacy', 'Privacy activée');
            privacy?.call(true);
          }
        }

        Widget seg(int v, IconData icon, String label, bool enabled) {
          final on = v == mode;
          return Tooltip(
            message: [
              'Le client et le technicien utilisent le PC',
              'Clavier et souris du client bloqués',
              'Écran masqué chez le client, clavier et souris bloqués',
            ][v],
            child: InkWell(
              onTap: enabled ? () => select(v) : null,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(color: on ? _teal : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 16, color: enabled ? (on ? Colors.white : _fg) : const Color(0xFF475569)),
                  if (!compact || on) ...[
                    const SizedBox(width: 6),
                    Text(label,
                        style: TextStyle(
                            color: enabled ? (on ? Colors.white : _fg) : const Color(0xFF475569),
                            fontSize: 12.5,
                            fontWeight: on ? FontWeight.w700 : FontWeight.w600)),
                  ],
                ]),
              ),
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.all(3),
          decoration:
              BoxDecoration(color: _ground, border: Border.all(color: _line), borderRadius: BorderRadius.circular(11)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            seg(0, Icons.groups_outlined, 'Partagé', true),
            const SizedBox(width: 3),
            seg(1, Icons.lock_outline, 'Tech uniquement', canBlock),
            const SizedBox(width: 3),
            seg(2, Icons.visibility_off_outlined, 'Privacy', privacy != null),
          ]),
        );
      });

  Widget _endBanner(CiCounterData d) {
    final left = d.endDeadline!.difference(DateTime.now()).inSeconds.clamp(0, 600);
    final who = (d.client ?? '').isNotEmpty ? d.client! : 'Le client';
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
          color: const Color(0x1FFBBF24),
          border: Border.all(color: const Color(0x73FBBF24)),
          borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        const Icon(Icons.error_outline, color: _amber, size: 20),
        const SizedBox(width: 8),
        Text.rich(
          TextSpan(children: [
            TextSpan(
                text: '$who demande la fin de l\'accès. ',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const TextSpan(text: 'Fin automatique dans '),
            TextSpan(text: ciClock(left), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ]),
          style: const TextStyle(color: Color(0xFFFDE68A), fontSize: 13),
        ),
        const SizedBox(width: 12),
        _filled('Terminer maintenant', _red, () => closeConnection(id: id)),
        const SizedBox(width: 8),
        _outlined(Icons.more_time, d.endExtended ? 'Déjà prolongé' : 'Encore 2 min',
            d.endExtended || _extending ? null : _extend),
      ]),
    );
  }

  Future<void> _extend() async {
    setState(() => _extending = true);
    try {
      final res = await CiTechApi.post('/api/v1/tech/end-extend', {'peer': id});
      if (res.statusCode == 200) {
        await bind.sessionSendChat(
            sessionId: ffi.sessionId, text: 'Votre technicien termine : encore 2 minutes et il se déconnecte.');
      } else {
        showToast('Prolongation impossible (${res.statusCode})');
      }
    } catch (_) {
      showToast('Serveur d\'assistance injoignable');
    }
    if (!mounted) return;
    setState(() => _extending = false);
    await reload();
  }

  // ---------------------------------------------------------------- actions

  void _files() {
    ciLog(ffi, 'files');
    connect(context, id, isFileTransfer: true, connToken: bind.sessionGetConnToken(sessionId: ffi.sessionId));
  }

  void _chat() {
    ffi.chatModel.changeCurrentKey(MessageKey(ffi.id, ChatModel.clientModeID));
    ffi.chatModel.toggleChatOverlay();
  }

  Widget _powerMenu() {
    final items = <PopupMenuEntry<VoidCallback>>[];
    if (_keyboard) {
      items.add(_entry(Icons.lock_outline, 'Verrouiller la session', () {
        ciLog(ffi, 'lock');
        bind.sessionLockScreen(sessionId: ffi.sessionId);
      }));
    }
    if (ffi.ffiModel.permissions['restart'] != false) {
      items.add(_entry(Icons.restart_alt, 'Redémarrer (reconnexion automatique)', () {
        ciLog(ffi, 'restart', 'Redémarrage demandé');
        showRestartRemoteDevice(ffi.ffiModel.pi, id, ffi.sessionId, ffi.dialogManager);
      }));
    }
    if (_keyboard && _windows) {
      items.addAll(kCiPower.map((c) => _entry(c.icon, c.label, () => ciRunWithConfirm(ffi, c))));
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<VoidCallback>(
      tooltip: 'Alimentation',
      color: _bg,
      position: PopupMenuPosition.under,
      onSelected: (f) => f(),
      itemBuilder: (_) => items,
      child: _toolFace(Icons.power_settings_new, 'Alim.'),
    );
  }

  Widget _qualityMenu() {
    const labels = {
      kRemoteImageQualityBalanced: 'Qualité : auto',
      kRemoteImageQualityBest: 'Qualité : max',
      kRemoteImageQualityLow: 'Qualité : fluide',
    };
    return PopupMenuButton<String>(
      tooltip: 'Qualité d\'image',
      color: _bg,
      position: PopupMenuPosition.under,
      onSelected: (q) async {
        await bind.sessionSetImageQuality(sessionId: ffi.sessionId, value: q);
        if (mounted) setState(() => _quality = q);
      },
      itemBuilder: (_) => [
        for (final e in labels.entries)
          PopupMenuItem(
              value: e.key,
              child: Text(
                  {
                    kRemoteImageQualityBalanced: 'Équilibrée (automatique)',
                    kRemoteImageQualityBest: 'Meilleure image',
                    kRemoteImageQualityLow: 'Plus fluide (connexion lente)',
                  }[e.key]!,
                  style: TextStyle(color: e.key == _quality ? const Color(0xFF5EEAD4) : _fg, fontSize: 13))),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(border: Border.all(color: _line), borderRadius: BorderRadius.circular(8)),
        child: Text(labels[_quality] ?? 'Qualité : perso', style: const TextStyle(color: _muted, fontSize: 12)),
      ),
    );
  }

  Future<void> _palette() async {
    final recent = bind.mainGetLocalOption(key: _kRecentOption).split('\n').where((s) => s.isNotEmpty).toList();
    final all = [...kCiTools, ...kCiDiagnostics];
    final query = TextEditingController();
    final picked = await ffi.dialogManager.show<CiCommand>((setState, close, context) {
      final q = query.text.trim().toLowerCase();
      bool match(CiCommand c) => q.isEmpty || c.label.toLowerCase().contains(q) || c.command.toLowerCase().contains(q);
      final groups = <String, List<CiCommand>>{
        if (q.isEmpty) 'Récents': recent.map((l) => all.firstWhereOrNull((c) => c.label == l)).whereType<CiCommand>().toList(),
        'Windows': kCiTools.where((c) => !_kConsole.contains(c.command) && match(c)).toList(),
        'Diagnostic': kCiDiagnostics.where(match).toList(),
        'Console': kCiTools.where((c) => _kConsole.contains(c.command) && match(c)).toList(),
      }..removeWhere((_, v) => v.isEmpty);
      return CustomAlertDialog(
        title: const Text('Outils'),
        contentBoxConstraints: const BoxConstraints(maxWidth: 620),
        content: SizedBox(
          width: 600,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                final first = groups.values.expand((v) => v).firstOrNull;
                if (first != null) close(first);
              },
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search), hintText: 'Rechercher une action (gestionnaire, réseau, disque…)'),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (groups.isEmpty) const Text('Aucune action ne correspond.'),
                  for (final g in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
                      child: Text(g.key.toUpperCase(),
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Color(0xFF0F766E))),
                    ),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final c in g.value)
                        ActionChip(
                          avatar: Icon(c.icon, size: 16),
                          label: Text(c.label),
                          onPressed: () => close(c),
                        ),
                    ]),
                  ],
                ]),
              ),
            ),
          ]),
        ),
        actions: [dialogButton('Cancel', onPressed: close, isOutline: true)],
        onCancel: close,
      );
    });
    query.dispose();
    if (picked == null) return;
    final next = [picked.label, ...recent.where((l) => l != picked.label)].take(5).join('\n');
    bind.mainSetLocalOption(key: _kRecentOption, value: next);
    await ciRunWithConfirm(ffi, picked);
  }

  // ---------------------------------------------------------------- éléments

  PopupMenuItem<VoidCallback> _entry(IconData icon, String label, VoidCallback f) => PopupMenuItem(
      value: f,
      child: Row(children: [
        Icon(icon, size: 17, color: _fg),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: _fg, fontSize: 13)),
      ]));

  Widget _sep() => Container(width: 1, height: 30, color: _line, margin: const EdgeInsets.symmetric(horizontal: 10));

  TextStyle _num(Color c) => TextStyle(
      color: c, fontSize: 17, fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()]);

  Widget _toolFace(IconData icon, String label) => SizedBox(
        width: 58,
        height: 50,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 20, color: _fg),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: _fg, fontSize: 11)),
        ]),
      );

  Widget _tool(IconData icon, String label, VoidCallback onTap) => Tooltip(
        message: label,
        child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(10), child: _toolFace(icon, label)),
      );

  Widget _square(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(border: Border.all(color: _line), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 19, color: _fg),
          ),
        ),
      );

  Widget _outlined(IconData icon, String label, VoidCallback? onTap, {bool compact = false}) => Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(border: Border.all(color: _line), borderRadius: BorderRadius.circular(10)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: onTap == null ? const Color(0xFF475569) : _fg),
              if (!compact) ...[
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color: onTap == null ? const Color(0xFF475569) : _fg,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
        ),
      );

  Widget _filled(String label, Color color, VoidCallback onTap) => SizedBox(
        height: 38,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 15),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
        ),
      );
}
