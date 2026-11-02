// Concept Informatique : compteur de temps de la session (F-17), relié au crédit support du client.
//
// Affiche le solde : négatif tant qu'il reste du crédit (« -29:41 »), positif au-delà avec le prix du
// dépassement (« +00:20 · 0,20 € »). Les premières minutes de la session sont offertes (« Offert 3:12 »).
// Le serveur d'assistance donne le temps connecté, le crédit et les réglages (GET …/counter) ; l'app
// compte seule chaque seconde et relit le serveur toutes les 20 s.
//
// - app technicien : pastille dans la barre d'actions de la fenêtre de session ;
// - app client : overlay de session (ci_cm_shell.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/ci_client_home.dart';
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
  final String? client;
  final String? hostname;
  final DateTime fetchedAt;

  /// Demande de fin du client : heure locale de la coupure automatique (null : pas de demande).
  final DateTime? endDeadline;
  final bool endExtended;

  CiCounterData.fromJson(Map<String, dynamic> j)
      : active = j['active'] == true,
        running = j['running'] == true,
        seconds = (j['seconds'] as num?)?.toInt() ?? 0,
        freeSeconds = (j['free_seconds'] as num?)?.toInt() ?? 0,
        rate = (j['rate'] as num?)?.toDouble() ?? 0,
        credit = (j['credit_seconds'] as num?)?.toInt(),
        peerName = j['peer_name'] as String?,
        client = j['client'] as String?,
        hostname = j['hostname'] as String?,
        fetchedAt = DateTime.now(),
        endDeadline = _localTime(j, (j['end_request'] as Map?)?['deadline']),
        endExtended = (j['end_request'] as Map?)?['extended'] == true;

  static DateTime? _localTime(Map<String, dynamic> j, Object? serverTs) {
    final server = (j['server_time'] as num?)?.toDouble();
    if (serverTs is! num || server == null) return null;
    return DateTime.now()
        .add(Duration(milliseconds: ((serverTs - server) * 1000).round()));
  }

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
mixin CiCounterPoller<T extends StatefulWidget> on State<T> {
  CiCounterData? data;
  String? error;
  Timer? _tick;
  Timer? _fetch;

  Future<http.Response> request();

  void startPolling() {
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    reload();
  }

  Future<void> reload() async {
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
    _fetch = Timer(next, reload);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _fetch?.cancel();
    super.dispose();
  }
}
