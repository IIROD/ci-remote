// Concept Informatique : compteur de temps de la session (F-17), relié au crédit support du client.
//
// Affiche le solde : négatif tant qu'il reste du crédit (« -29:41 »), positif au-delà avec le prix du
// dépassement (« +00:20 · 0,20 € »). Les premières minutes de la session sont offertes (« Offert 3:12 »).
// Le serveur d'assistance donne le temps connecté, le crédit et les réglages (GET …/counter) ; l'app
// compte seule chaque seconde et relit le serveur toutes les 20 s.
//
// - app technicien : pastille dans la barre d'onglets de la fenêtre de session (et dans la barre
//   d'outils en plein écran) ;
// - app client : encart dans la fenêtre de connexion.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/ci_client_home.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

bool get isCiTech => kCiRole == 'tech';

const _kRefresh = Duration(seconds: 20);
const _kRetry = Duration(seconds: 5);
const kCiOver = Color(0xFFB45309);
const kCiOverBg = Color(0xFFFFFBEB);
const kCiGift = Color(0xFF7C3AED);

class CiCounterData {
  final bool active;
  final bool running;
  final int seconds;
  final int freeSeconds;
  final double rate;
  final int? credit;
  final String? peerName;
  final DateTime fetchedAt;

  CiCounterData.fromJson(Map<String, dynamic> j)
      : active = j['active'] == true,
        running = j['running'] == true,
        seconds = (j['seconds'] as num?)?.toInt() ?? 0,
        freeSeconds = (j['free_seconds'] as num?)?.toInt() ?? 0,
        rate = (j['rate'] as num?)?.toDouble() ?? 0,
        credit = (j['credit_seconds'] as num?)?.toInt(),
        peerName = j['peer_name'] as String?,
        fetchedAt = DateTime.now();

  /// Temps connecté à l'instant, compté localement depuis la dernière lecture.
  int get secondsNow => seconds +
      (active && running ? DateTime.now().difference(fetchedAt).inSeconds : 0);
  int get freeLeft => math.max(0, freeSeconds - secondsNow);
  int get billable => math.max(0, secondsNow - freeSeconds);

  /// Solde affiché : négatif = crédit restant, positif = dépassement.
  int get balance => billable - (credit ?? 0);
  double get overPrice => balance > 0 ? balance * rate / 3600 : 0;
}

String ciClock(int seconds) {
  final s = seconds.abs();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(r)}' : '${two(m)}:${two(r)}';
}

String ciSigned(int seconds) =>
    '${seconds < 0 ? '-' : seconds > 0 ? '+' : ''}${ciClock(seconds)}';

String ciEuros(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} €';

/// Lit le compteur et fait avancer l'affichage chaque seconde.
mixin _CounterPoller<T extends StatefulWidget> on State<T> {
  CiCounterData? data;
  String? error;
  Timer? _tick;
  Timer? _fetch;

  Future<http.Response> request();

  void startPolling() {
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  Future<void> _load() async {
    _fetch?.cancel();
    Duration next = _kRefresh;
    try {
      final res = await request();
      if (res.statusCode == 200) {
        data = CiCounterData.fromJson(
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
        error = null;
        if (!data!.active) next = _kRetry; // session pas encore notée par le serveur
      } else {
        error = res.statusCode == 401
            ? 'Reconnectez-vous dans la console technicien'
            : 'Compteur indisponible (${res.statusCode})';
        next = _kRetry;
      }
    } catch (_) {
      error = 'Serveur d\'assistance injoignable';
      next = _kRetry;
    }
    if (!mounted) return;
    setState(() {});
    _fetch = Timer(next, _load);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _fetch?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------- technicien

/// Pastille de l'app technicien : compacte, à côté des onglets de la fenêtre de session.
class CiTechCounter extends StatefulWidget {
  final String peerId;

  /// Dans la barre d'outils : visible seulement en plein écran (la barre d'onglets est alors masquée).
  final bool fullscreenOnly;

  const CiTechCounter(
      {Key? key, required this.peerId, this.fullscreenOnly = false})
      : super(key: key);

  @override
  State<CiTechCounter> createState() => _CiTechCounterState();
}

class _CiTechCounterState extends State<CiTechCounter>
    with _CounterPoller<CiTechCounter> {
  @override
  void initState() {
    super.initState();
    startPolling();
  }

  @override
  Future<http.Response> request() async {
    final base = (await bind.mainGetApiServer()).replaceAll(RegExp(r'/+$'), '');
    return http.get(
        Uri.parse(
            '$base/api/v1/tech/counter?peer=${Uri.encodeQueryComponent(widget.peerId)}'),
        headers: {
          'Authorization':
              'Bearer ${bind.mainGetLocalOption(key: 'ci-tech-token')}',
          'X-CI-Device': await bind.mainGetMyId(),
        }).timeout(const Duration(seconds: 10));
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final narrow = MediaQuery.of(context).size.width < 760;
    Color fg = kCiMuted, bg = const Color(0xFFF1F5F9);
    final parts = <Widget>[];
    String tip;
    if (d == null || !d.active) {
      final text = error ?? 'Compteur…';
      parts.add(Text(narrow ? '--:--' : text, style: _style(fg)));
      tip = error ?? 'En attente du serveur d\'assistance';
    } else {
      final over = d.balance > 0;
      fg = over ? kCiOver : kCiBrandDark;
      bg = over ? kCiOverBg : const Color(0xFFE6F6F4);
      parts.add(Text(ciSigned(d.balance), style: _style(fg, mono: true)));
      if (over && d.rate > 0) {
        parts.add(Text('  ${ciEuros(d.overPrice)}',
            style: _style(fg, weight: FontWeight.w600)));
      }
      if (d.freeLeft > 0) {
        parts.add(const SizedBox(width: 8));
        parts.add(_chip(narrow ? ciClock(d.freeLeft) : 'Offert ${ciClock(d.freeLeft)}'));
      }
      tip = [
        if (d.credit == null) 'PC non rattaché à un compte client',
        'Temps connecté : ${ciClock(d.secondsNow)}',
        if (d.freeSeconds > 0) '${d.freeSeconds ~/ 60} min offertes au début',
        if (d.credit != null)
          'Crédit au début de la session : ${d.credit! < 0 ? '-' : ''}${ciClock(d.credit!)}',
        if (d.rate > 0) 'Dépassement : ${ciEuros(d.rate)} / h (affiché seulement)',
      ].join('\n');
    }
    final pill = Tooltip(
      message: tip,
      child: Container(
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: fg.withOpacity(0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.timer_outlined, size: 14, color: fg),
          const SizedBox(width: 4),
          ...parts,
        ]),
      ),
    );
    if (!widget.fullscreenOnly) return Center(child: pill);
    return Obx(() => stateGlobal.fullscreen.isTrue
        ? Center(child: pill)
        : const SizedBox.shrink());
  }

  TextStyle _style(Color c, {bool mono = false, FontWeight? weight}) =>
      TextStyle(
        color: c,
        fontSize: 12,
        fontWeight: weight ?? FontWeight.w700,
        fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
      );

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
            color: kCiGift.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.card_giftcard, size: 11, color: kCiGift),
          const SizedBox(width: 3),
          Text(text,
              style: const TextStyle(
                  color: kCiGift,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      );
}

// ---------------------------------------------------------------- client

/// Encart de l'app client, dans la fenêtre de connexion (pendant la session).
class CiClientCounter extends StatefulWidget {
  const CiClientCounter({Key? key}) : super(key: key);

  @override
  State<CiClientCounter> createState() => _CiClientCounterState();
}

class _CiClientCounterState extends State<CiClientCounter>
    with _CounterPoller<CiClientCounter> {
  @override
  void initState() {
    super.initState();
    startPolling();
  }

  @override
  Future<http.Response> request() => CiDeviceApi.get('/api/v1/device/counter');

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null || !d.active) {
      return _box(kCiMuted, Colors.white, [
        Text(error ?? 'Compteur de temps…',
            style: const TextStyle(color: kCiMuted, fontSize: 12)),
      ]);
    }
    final over = d.balance > 0;
    final fg = over ? kCiOver : kCiBrandDark;
    final String detail;
    if (d.freeLeft > 0) {
      detail = 'Les ${d.freeSeconds ~/ 60} premières minutes sont offertes';
    } else if (d.credit == null) {
      detail = 'Temps facturable de la session';
    } else if (over) {
      detail = d.rate > 0
          ? 'Crédit épuisé · ${ciEuros(d.rate)} / heure'
          : 'Crédit épuisé';
    } else {
      detail = 'Crédit restant';
    }
    return _box(fg, over ? kCiOverBg : Colors.white, [
      Row(children: [
        Icon(Icons.timer_outlined, size: 16, color: fg),
        const SizedBox(width: 6),
        const Expanded(
          child: Text('Temps d\'assistance',
              style: TextStyle(
                  color: kCiInk, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        if (d.freeLeft > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
                color: kCiGift.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8)),
            child: Text('Offert ${ciClock(d.freeLeft)}',
                style: const TextStyle(
                    color: kCiGift,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ),
      ]),
      const SizedBox(height: 4),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic, children: [
          Text(ciSigned(d.balance),
              style: TextStyle(
                  color: fg,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          if (over && d.rate > 0)
            Text('  ${ciEuros(d.overPrice)}',
                style: TextStyle(
                    color: fg, fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
      ),
      Text('$detail · connecté ${ciClock(d.secondsNow)}',
          style: const TextStyle(color: kCiMuted, fontSize: 11)),
    ]);
  }

  Widget _box(Color accent, Color bg, List<Widget> children) => Container(
        margin: const EdgeInsets.fromLTRB(5, 0, 5, 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: accent.withOpacity(0.35)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children),
      );
}
