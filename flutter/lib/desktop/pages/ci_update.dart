// Concept Informatique : mise à jour automatique des apps client et technicien (Windows, exe portable).
//
// Le serveur d'assistance donne la version épinglée par pull request (GET …/device/app ou …/tech/app :
// numéro de build, SHA-256, adresse sur GitHub). Si elle est plus récente que celle-ci (numéro fixé à la
// compilation, CI_BUILD), l'app la télécharge à côté de son exe, vérifie l'empreinte, puis remplace
// l'exe sous le même nom (le code de rattachement au compte est dans le nom) et le relance : le lanceur
// voit une nouvelle version, arrête l'ancienne et extrait la nouvelle (libs/portable).
//
// App client : sans rien demander, hors session. App technicien : bandeau « Redémarrer ». Jamais de
// retour en arrière : une version épinglée plus ancienne est ignorée.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/ci_actions.dart';
import 'package:flutter_hbb/desktop/pages/ci_client_home.dart';
import 'package:http/http.dart' as http;

const kCiBuild = String.fromEnvironment('CI_BUILD');
const _kEvery = Duration(hours: 6);
const _kBusyRetry = Duration(minutes: 10);
const _kMaxSize = 200 << 20;

int ciBuildNumber(String tag) => int.tryParse(tag.replaceFirst('build-', '')) ?? 0;

class CiUpdater {
  /// Version téléchargée et vérifiée, prête à être installée (null : rien à faire).
  static final ready = ValueNotifier<String?>(null);
  static Timer? _timer;
  static bool _busy = false;
  static String? _file;
  static String? _target;

  static bool get _tech => kCiRole == 'tech';

  /// Au démarrage de l'accueil (une seule fois), puis toutes les 6 h.
  static void start() {
    if (!Platform.isWindows || ciBuildNumber(kCiBuild) == 0 || _timer != null) return;
    _removeLeftovers();
    _timer = Timer.periodic(_kEvery, (_) => check());
    check();
  }

  /// Chemin de l'exe téléchargé par le client (le lanceur), pas celui qu'il a extrait.
  static String? _outerExe() {
    final env = Platform.environment;
    final full = env['CI_PORTABLE_EXE'];
    if (full != null && full.isNotEmpty && File(full).existsSync()) return full;
    // Lanceurs plus anciens : seul le nom est transmis, on le cherche aux endroits habituels.
    final name = env['RUSTDESK_APPNAME'], home = env['USERPROFILE'];
    if (name == null || name.isEmpty || home == null) return null;
    for (final dir in ['Downloads', 'Desktop', 'Documents']) {
      final path = '$home\\$dir\\$name';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static void _removeLeftovers() {
    final target = _outerExe();
    if (target == null) return;
    for (final suffix in ['.update', '.old']) {
      try {
        final f = File('$target$suffix');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  static Future<void> check() async {
    if (_busy || ready.value != null) return;
    _busy = true;
    try {
      final target = _outerExe();
      if (target == null) return;
      final res = _tech ? await CiTechApi.get('/api/v1/tech/app') : await CiDeviceApi.get('/api/v1/device/app');
      if (res.statusCode != 200) return;
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final tag = j['tag'] as String? ?? '';
      final sha = (j['sha256'] as String? ?? '').toLowerCase();
      final url = j['url'] as String? ?? '';
      if (ciBuildNumber(tag) <= ciBuildNumber(kCiBuild) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
          !url.startsWith('https://github.com/')) {
        return;
      }
      final file = File('$target.update');
      await _download(url, file);
      if (await _sha256(file.path) != sha) {
        file.deleteSync();
        debugPrint('Concept Informatique : mise à jour $tag refusée (empreinte différente)');
        return;
      }
      _file = file.path;
      _target = target;
      ready.value = tag;
      if (!_tech) unawaited(_applyWhenIdle());
    } catch (e) {
      debugPrint('Concept Informatique : mise à jour : $e');
    } finally {
      _busy = false;
    }
  }

  static Future<void> _download(String url, File out) async {
    final client = http.Client();
    IOSink? sink;
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(minutes: 1));
      if (res.statusCode != 200) throw 'téléchargement : HTTP ${res.statusCode}';
      sink = out.openWrite();
      var size = 0;
      await for (final chunk in res.stream.timeout(const Duration(minutes: 2))) {
        size += chunk.length;
        if (size > _kMaxSize) throw 'fichier trop gros';
        sink.add(chunk);
      }
      await sink.close();
      sink = null;
    } catch (_) {
      await sink?.close();
      if (out.existsSync()) out.deleteSync();
      rethrow;
    } finally {
      client.close();
    }
  }

  /// SHA-256 par l'outil de Windows (certutil), sans dépendance de plus.
  static Future<String> _sha256(String path) async {
    final r = await Process.run('certutil', ['-hashfile', path, 'SHA256']);
    for (final line in r.stdout.toString().split(RegExp(r'\r?\n'))) {
      final hex = line.replaceAll(' ', '').trim().toLowerCase();
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return hex;
    }
    return '';
  }

  /// App client : jamais pendant une intervention (session ouverte côté serveur).
  static Future<void> _applyWhenIdle() async {
    try {
      final res = await CiDeviceApi.get('/api/v1/device/counter');
      final busy = res.statusCode != 200 || (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['active'] == true;
      if (busy) {
        Timer(_kBusyRetry, _applyWhenIdle);
        return;
      }
    } catch (_) {
      Timer(_kBusyRetry, _applyWhenIdle);
      return;
    }
    await apply();
  }

  /// Remplace l'exe et le relance ; le lanceur arrête cette version et démarre la nouvelle.
  static Future<bool> apply() async {
    final file = _file, target = _target;
    if (file == null || target == null) return false;
    final old = File('$target.old');
    try {
      if (old.existsSync()) old.deleteSync();
      await File(target).rename(old.path);
      await File(file).rename(target);
    } catch (e) {
      debugPrint('Concept Informatique : remplacement impossible : $e');
      if (!File(target).existsSync() && old.existsSync()) await old.rename(target);
      return false;
    }
    try {
      old.deleteSync();
    } catch (_) {}
    await Process.start(target, [], mode: ProcessStartMode.detached, workingDirectory: File(target).parent.path);
    return true;
  }
}

/// Bandeau de l'app technicien quand une nouvelle version est prête.
class CiUpdateBanner extends StatelessWidget {
  const CiUpdateBanner({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
        valueListenable: CiUpdater.ready,
        builder: (context, tag, _) {
          if (tag == null) return const SizedBox.shrink();
          return Material(
            color: const Color(0xFFE6F6F4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                const Icon(Icons.system_update_alt, color: kCiBrandDark, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      'Nouvelle version prête (${tag.replaceFirst('build-', 'build ')}). '
                      'Terminez vos sessions en cours, puis redémarrez l\'app.',
                      style: const TextStyle(color: kCiInk, fontSize: 13)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (!await CiUpdater.apply()) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
                          content: Text('Mise à jour impossible : relancez l\'app, elle réessaiera.')));
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: kCiBrandDark, foregroundColor: Colors.white),
                  child: const Text('Redémarrer'),
                ),
              ]),
            ),
          );
        },
      );
}
