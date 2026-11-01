// Concept Informatique : page d'accueil de l'app client (F-14).
//
// Une seule page à nos couleurs : le client (fiche du compte du site), ce PC (nom, propriétaire
// modifiable, numéro d'assistance), le bouton « Demande d'aide » et l'état du service.
// Les données viennent de l'API d'assistance (docs/API-RUSTDESK.md du dépôt Concept_Assist).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';

/// Version de l'app, fixée à la compilation : `--dart-define=CI_ROLE=tech` pour l'app technicien.
const String kCiRole =
    String.fromEnvironment('CI_ROLE', defaultValue: 'client');
bool get isCiClient => kCiRole == 'client';

const kCiBrand = Color(0xFF04A595);
const kCiBrandDark = Color(0xFF038578);
const kCiInk = Color(0xFF1E293B);
const kCiMuted = Color(0xFF64748B);
const kCiLine = Color(0xFFE2E8F0);
const kCiBg = Color(0xFFF4F7F9);
const kCiShopPhone = '069 57 59 11';
const kCiClientSize = Size(420, 680);

/// Appels de l'app client : le PC s'identifie par son ID, son identifiant machine et le code de
/// téléchargement qui l'a rattaché au compte (src/ci_remote.rs).
class CiDeviceApi {
  static Future<Map<String, String>> _headers() async => {
        'Content-Type': 'application/json',
        'X-CI-Device': await bind.mainGetMyId(),
        'X-CI-Uuid': await bind.mainGetUuid(),
        'X-CI-Token': bind.mainGetLocalOption(key: 'ci-download-token'),
      };

  static Future<Uri> _uri(String path) async {
    final base = (await bind.mainGetApiServer()).replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  static Future<http.Response> get(String path) async => http
      .get(await _uri(path), headers: await _headers())
      .timeout(const Duration(seconds: 10));

  static Future<http.Response> post(
          String path, Map<String, dynamic> body) async =>
      http
          .post(await _uri(path),
              headers: await _headers(), body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
}

/// Thème clair à nos couleurs, imposé à nos pages (indépendant du thème sombre ou clair de Windows).
ThemeData ciTheme() {
  final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kCiLine));
  return ThemeData(
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
        seedColor: kCiBrand, brightness: Brightness.light, primary: kCiBrand),
    scaffoldBackgroundColor: kCiBg,
    textSelectionTheme: const TextSelectionThemeData(cursorColor: kCiBrand),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      labelStyle: const TextStyle(color: kCiMuted),
      floatingLabelStyle: const TextStyle(color: kCiBrandDark),
      prefixIconColor: kCiMuted,
      suffixIconColor: kCiMuted,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
          borderSide: const BorderSide(color: kCiBrand, width: 2)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kCiBrand,
        foregroundColor: Colors.white,
        disabledBackgroundColor: kCiLine,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kCiBrandDark,
        side: const BorderSide(color: kCiBrand),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: kCiBrandDark)),
    dialogTheme: DialogTheme(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
  );
}

enum _Link { loading, linked, notLinked, unreachable }

class CiClientHome extends StatefulWidget {
  const CiClientHome({Key? key}) : super(key: key);

  @override
  State<CiClientHome> createState() => _CiClientHomeState();
}

class _CiClientHomeState extends State<CiClientHome> {
  Timer? _statusTimer;
  Timer? _refreshTimer;
  int _svc =
      0; // 1 : connecté au service, 0 : connexion en cours, -1 : hors ligne
  _Link _link = _Link.loading;
  Map<String, dynamic> _me = {};
  Map<String, dynamic>? _usage;
  String _myId = '';
  bool _editingOwner = false;
  bool _savingOwner = false;
  bool _sending = false;
  String? _notice;
  bool _noticeIsError = false;
  final _ownerCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    imcomingOnlyHomeSize = kCiClientSize;
    windowManager.setSize(getIncomingOnlyHomeSize());
    bind.mainGetMyId().then((id) {
      if (mounted) setState(() => _myId = id);
    });
    _statusTimer =
        periodic_immediate(const Duration(seconds: 1), _updateStatus);
    _refreshTimer = periodic_immediate(const Duration(seconds: 30), _refresh);
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _refreshTimer?.cancel();
    _ownerCtrl.dispose();
    super.dispose();
  }

  Future<void> _updateStatus() async {
    try {
      final status =
          jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
      final num = status['status_num'] as int? ?? -1;
      final svc = num == 1 ? 1 : (num == 0 ? 0 : -1);
      if (mounted && svc != _svc) setState(() => _svc = svc);
    } catch (_) {}
  }

  Future<void> _refresh() async {
    _Link link;
    Map<String, dynamic>? me;
    try {
      final res = await CiDeviceApi.get('/api/v1/device/me');
      if (res.statusCode == 200) {
        me = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        link = _Link.linked;
      } else {
        link = res.statusCode == 401 ? _Link.notLinked : _Link.unreachable;
      }
    } catch (_) {
      link = _Link.unreachable;
    }
    Map<String, dynamic>? usage;
    if (link == _Link.linked) {
      try {
        final res = await CiDeviceApi.get('/api/v1/device/usage');
        if (res.statusCode == 200) {
          usage = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _link = link;
      if (me != null) _me = me;
      if (usage != null) _usage = usage;
    });
  }

  Map<String, dynamic> get _account =>
      (_me['account'] as Map<String, dynamic>?) ?? {};
  bool get _helpOpen => (_me['help'] as Map<String, dynamic>?)?['open'] == true;

  String get _formattedId {
    final id = _myId.replaceAll(' ', '');
    if (!RegExp(r'^\d+$').hasMatch(id)) return id;
    final buf = StringBuffer();
    for (var i = 0; i < id.length; i++) {
      if (i > 0 && (id.length - i) % 3 == 0) buf.write(' ');
      buf.write(id[i]);
    }
    return buf.toString();
  }

  void _say(String text, {bool error = false}) {
    setState(() {
      _notice = text;
      _noticeIsError = error;
    });
  }

  Future<void> _saveOwner() async {
    setState(() => _savingOwner = true);
    try {
      final res = await CiDeviceApi.post(
          '/api/v1/device/owner', {'owner': _ownerCtrl.text.trim()});
      if (res.statusCode == 200) {
        _editingOwner = false;
        await _refresh();
      } else {
        _say("Le propriétaire n'a pas pu être enregistré. Réessayez plus tard.",
            error: true);
      }
    } catch (_) {
      _say("Pas de connexion au service : réessayez dans un instant.",
          error: true);
    }
    if (mounted) setState(() => _savingOwner = false);
  }

  Future<void> _askHelp() async {
    final msgCtrl = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Demande d'aide"),
        content: SizedBox(
          width: 340,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    "Nous vous recontactons au plus vite. Décrivez votre problème en quelques mots (facultatif) :",
                    style: TextStyle(color: kCiMuted)),
                const SizedBox(height: 12),
                TextField(
                  controller: msgCtrl,
                  maxLines: 4,
                  maxLength: 500,
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: "Ex. : mon imprimante ne fonctionne plus",
                      border: OutlineInputBorder()),
                ),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: kCiBrand, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Envoyer la demande'),
          ),
        ],
      ),
    );
    final message = msgCtrl.text.trim();
    msgCtrl.dispose();
    if (send != true) return;
    setState(() => _sending = true);
    try {
      final res =
          await CiDeviceApi.post('/api/v1/device/help', {'message': message});
      if (res.statusCode == 200) {
        _say("Demande envoyée. Un technicien vous recontacte rapidement.");
        await _refresh();
      } else if (res.statusCode == 429) {
        _say(
            "Vous avez déjà envoyé plusieurs demandes. Pour une urgence, appelez le $kCiShopPhone.",
            error: true);
      } else {
        _say(
            "La demande n'a pas pu être envoyée. Appelez-nous au $kCiShopPhone.",
            error: true);
      }
    } catch (_) {
      _say("Pas de connexion au service. Appelez-nous au $kCiShopPhone.",
          error: true);
    }
    if (mounted) setState(() => _sending = false);
  }

  // ---------- affichage ----------

  @override
  Widget build(BuildContext context) {
    return Theme(data: ciTheme(), child: _page());
  }

  Widget _page() {
    return Container(
      color: kCiBg,
      child: Column(children: [
        _header(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_link == _Link.notLinked)
                    _banner(
                        "Ce PC n'est pas encore relié à votre compte. Téléchargez l'app depuis votre espace client "
                        "sur conceptinformatique.be, ou appelez-nous au $kCiShopPhone.",
                        error: true),
                  if (_link == _Link.unreachable)
                    _banner(
                        "Impossible de joindre le service d'assistance pour le moment. Vérifiez votre connexion à "
                        "Internet.",
                        error: true),
                  _clientCard(),
                  const SizedBox(height: 12),
                  _pcCard(),
                  const SizedBox(height: 16),
                  _helpButton(),
                  if (_usage != null) ...[
                    const SizedBox(height: 16),
                    _usageCard(_usage!),
                  ],
                  if (_notice != null) ...[
                    const SizedBox(height: 10),
                    Text(_notice!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: _noticeIsError
                                ? const Color(0xFFB91C1C)
                                : kCiBrandDark,
                            fontSize: 13)),
                  ],
                ]),
          ),
        ),
        _footer(),
      ]),
    );
  }

  Widget _header() {
    final (label, color) = switch (_svc) {
      1 => ('Service connecté', const Color(0xFF16A34A)),
      0 => ('Connexion au service…', const Color(0xFFD97706)),
      _ => ('Service hors ligne', const Color(0xFFDC2626)),
    };
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: kCiBrand, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(children: [
        Image.asset('assets/ci_logo.png',
            height: 56, filterQuality: FilterQuality.medium),
        const SizedBox(height: 6),
        const Text('Assistance à distance',
            style: TextStyle(
                color: kCiInk, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }

  Widget _banner(String text, {bool error = false}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: error ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDFA),
          border: Border.all(color: error ? const Color(0xFFFCA5A5) : kCiBrand),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: const TextStyle(color: kCiInk, fontSize: 13)),
      );

  Widget _card(IconData icon, String title, List<Widget> rows) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: kCiLine),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: kCiBrand),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    color: kCiInk, fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          ...rows,
        ]),
      );

  Widget _row(String label, String? value,
          {Widget? trailing, bool mono = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(
              width: 118,
              child: Text(label,
                  style: const TextStyle(color: kCiMuted, fontSize: 13))),
          Expanded(
            child: SelectableText(
              (value == null || value.isEmpty) ? '—' : value,
              style: TextStyle(
                  color: kCiInk,
                  fontSize: 13.5,
                  fontFamily: mono ? 'monospace' : null),
            ),
          ),
          if (trailing != null) trailing,
        ]),
      );

  Widget _clientCard() {
    final a = _account;
    final name = [a['first_name'], a['last_name']]
        .where((v) => v is String && v.isNotEmpty)
        .join(' ');
    return _card(Icons.person_outline, 'Client', [
      _row('Nom', _link == _Link.loading ? '…' : name),
      if ((a['email'] as String? ?? '').isNotEmpty)
        _row('Email', a['email'] as String),
      if ((a['phone'] as String? ?? '').isNotEmpty)
        _row('Téléphone', a['phone'] as String),
    ]);
  }

  /// « Mon suivi » : crédit, temps du mois et dernières interventions (tous les PC du compte).
  Widget _usageCard(Map<String, dynamic> u) {
    final credit = (u['credit_seconds'] as num?)?.toInt();
    final free = (u['free_seconds'] as num?)?.toInt() ?? 0;
    final month = (u['month'] as Map<String, dynamic>?) ?? {};
    final monthCount = (month['sessions'] as num?)?.toInt() ?? 0;
    final monthBilled = (month['billed_seconds'] as num?)?.toInt() ?? 0;
    final sessions = ((u['sessions'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .take(5)
        .toList();
    final over = credit != null && credit < 0;
    return _card(Icons.insights_outlined, 'Mon suivi', [
      if (credit != null)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: over ? const Color(0xFFFFFBEB) : const Color(0xFFE6F6F4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(over ? 'Crédit dépassé de' : 'Crédit restant',
                style: const TextStyle(color: kCiMuted, fontSize: 12)),
            Text(_duration(credit.abs()),
                style: TextStyle(
                    color: over ? const Color(0xFFB45309) : kCiBrandDark,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
          ]),
        ),
      _row('Ce mois-ci',
          '$monthCount intervention${monthCount > 1 ? 's' : ''} · ${_duration(monthBilled)} décompté${monthBilled > 0 ? 's' : ''}'),
      if (sessions.isNotEmpty) ...[
        const SizedBox(height: 6),
        const Text('Dernières interventions',
            style: TextStyle(
                color: kCiMuted, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        ...sessions.map(_sessionRow),
      ],
      if (free > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
              'Les ${free ~/ 60} premières minutes de chaque intervention sont offertes.',
              style: const TextStyle(color: kCiMuted, fontSize: 11.5)),
        ),
    ]);
  }

  Widget _sessionRow(Map<String, dynamic> s) {
    final at = DateTime.fromMillisecondsSinceEpoch(
        (((s['started_at'] as num?) ?? 0) * 1000).toInt());
    String two(int v) => v.toString().padLeft(2, '0');
    final when =
        '${two(at.day)}/${two(at.month)} ${two(at.hour)}:${two(at.minute)}';
    final seconds = (s['seconds'] as num?)?.toInt() ?? 0;
    final billed = (s['billed_seconds'] as num?)?.toInt() ?? 0;
    final open = s['open'] == true;
    final (status, color) = open
        ? ('en cours', kCiBrand)
        : billed == 0
            ? ('offert', const Color(0xFF7C3AED))
            : s['settled'] == true
                ? ('${_duration(billed)} décomptées', kCiMuted)
                : ('${_duration(billed)} à valider', const Color(0xFFB45309));
    final who = [s['hostname'], s['tech']]
        .whereType<String>()
        .where((v) => v.isNotEmpty)
        .join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: kCiLine))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$when · ${_duration(seconds)}',
                style: const TextStyle(color: kCiInk, fontSize: 13)),
            if (who.isNotEmpty)
              Text(who,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kCiMuted, fontSize: 11.5)),
          ]),
        ),
        const SizedBox(width: 8),
        Text(status,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  static String _duration(int seconds) {
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60;
    if (h > 0) return '$h h ${m.toString().padLeft(2, '0')}';
    if (m > 0) return '$m min';
    return '$seconds s';
  }

  Widget _pcCard() {
    final owner = _me['owner'] as String?;
    final ownerRow = _editingOwner
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ownerCtrl,
                  autofocus: true,
                  maxLength: 80,
                  onSubmitted: (_) => _saveOwner(),
                  decoration: const InputDecoration(
                    isDense: true,
                    counterText: '',
                    labelText: 'Propriétaire du PC',
                    hintText: 'Ex. : Lucas (mon fils)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Enregistrer',
                icon: _savingOwner
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check, color: kCiBrand),
                onPressed: _savingOwner ? null : _saveOwner,
              ),
              IconButton(
                tooltip: 'Annuler',
                icon: const Icon(Icons.close, color: kCiMuted),
                onPressed: () => setState(() => _editingOwner = false),
              ),
            ]),
          )
        : _row(
            'Propriétaire',
            (owner == null || owner.isEmpty) ? 'Titulaire du compte' : owner,
            trailing: _link == _Link.linked
                ? IconButton(
                    tooltip: 'Modifier : à qui est ce PC ?',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, color: kCiBrand),
                    onPressed: () => setState(() {
                      _ownerCtrl.text = owner ?? '';
                      _editingOwner = true;
                    }),
                  )
                : null,
          );
    return _card(Icons.computer_outlined, 'Ce PC', [
      _row('Nom du PC', _me['hostname'] as String?),
      ownerRow,
      _row("N° d'assistance", _formattedId, mono: true),
    ]);
  }

  Widget _helpButton() {
    final enabled = _link == _Link.linked && !_sending;
    return Column(children: [
      SizedBox(
        height: 52,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: kCiBrand,
            foregroundColor: Colors.white,
            disabledBackgroundColor: kCiLine,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          icon: _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.support_agent),
          label: Text(
              _helpOpen ? "Renvoyer une demande d'aide" : "Demande d'aide"),
          onPressed: enabled ? _askHelp : null,
        ),
      ),
      if (_helpOpen)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
              "Votre demande est bien reçue : un technicien vous recontacte.",
              textAlign: TextAlign.center,
              style: TextStyle(color: kCiBrandDark, fontSize: 13)),
        ),
    ]);
  }

  Widget _footer() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: kCiLine))),
        child: const Text(
          "Un technicien ne peut voir votre écran que si vous l'acceptez.\n"
          "Concept Informatique · $kCiShopPhone · conceptinformatique.be",
          textAlign: TextAlign.center,
          style: TextStyle(color: kCiMuted, fontSize: 11.5, height: 1.4),
        ),
      );
}
