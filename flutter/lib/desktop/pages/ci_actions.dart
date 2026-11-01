// Concept Informatique : actions de l'app technicien pendant une session (menu « Concept » de la barre
// d'outils, remote_toolbar.dart).
//
// - commandes prêtes : ouvertes chez le client par Win+R puis saisie du texte (indépendant de la
//   disposition du clavier, AZERTY compris) ;
// - mode « Tech uniquement » : clavier et souris du client bloqués (fonction RustDesk, Windows), le client
//   est prévenu par la discussion ; « Rendre la main » le débloque quelques minutes (mot de passe…) ;
// - alimentation : verrouiller, veille, éteindre (redémarrer passe par la fonction RustDesk, qui se
//   reconnecte seule : voir ci_reconnect.dart côté client).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;

class CiCommand {
  final String label;
  final IconData icon;
  final String command;
  final String? confirm;
  const CiCommand(this.label, this.icon, this.command, {this.confirm});
}

/// Outils Windows ouverts en un clic (aucune modification sans action du technicien).
const kCiTools = [
  CiCommand('Gestionnaire des tâches', Icons.monitor_heart_outlined, 'taskmgr'),
  CiCommand('Paramètres Windows', Icons.settings_outlined, 'ms-settings:'),
  CiCommand('Windows Update', Icons.system_update_alt, 'ms-settings:windowsupdate'),
  CiCommand('Programmes installés', Icons.apps_outlined, 'appwiz.cpl'),
  CiCommand('Gestionnaire de périphériques', Icons.memory, 'devmgmt.msc'),
  CiCommand('Connexions réseau', Icons.lan_outlined, 'ncpa.cpl'),
  CiCommand('Informations système', Icons.info_outline, 'msinfo32'),
  CiCommand('Nettoyage de disque', Icons.cleaning_services_outlined, 'cleanmgr'),
  CiCommand('Dossier des fichiers temporaires', Icons.folder_delete_outlined, '%temp%'),
  CiCommand('Panneau de configuration', Icons.tune, 'control'),
  CiCommand('Invite de commandes', Icons.terminal, 'cmd'),
  CiCommand('PowerShell', Icons.code, 'powershell'),
];

/// Diagnostics : une fenêtre de commande reste ouverte avec le résultat.
const kCiDiagnostics = [
  CiCommand('Adresse IP et réseau', Icons.router_outlined, 'cmd /k ipconfig /all'),
  CiCommand('Vider le cache DNS', Icons.dns_outlined, 'cmd /k ipconfig /flushdns'),
  CiCommand('Tester Internet (ping)', Icons.network_check, 'cmd /k ping -n 4 8.8.8.8'),
  CiCommand('Espace disque', Icons.storage, 'powershell -NoExit -Command "Get-PSDrive -PSProvider FileSystem"'),
  CiCommand('Vérifier les fichiers système (admin)', Icons.health_and_safety_outlined,
      'powershell -Command "Start-Process cmd -ArgumentList \'/k sfc /scannow\' -Verb RunAs"'),
];

const kCiPower = [
  CiCommand('Mettre en veille', Icons.bedtime_outlined,
      'rundll32.exe powrprof.dll,SetSuspendState 0,1,0',
      confirm: 'Mettre le PC du client en veille ? La session sera coupée jusqu\'à son réveil.'),
  CiCommand('Éteindre', Icons.power_settings_new, 'shutdown /s /t 0',
      confirm: 'Éteindre le PC du client ? La session sera terminée (pas de reconnexion).'),
];

const _kTypingDelay = Duration(milliseconds: 700);

/// Appels de l'app technicien à l'API d'assistance (jeton de la console, ID du poste).
class CiTechApi {
  static Future<Map<String, String>> _headers() async => {
        'Authorization': 'Bearer ${bind.mainGetLocalOption(key: 'ci-tech-token')}',
        'X-CI-Device': await bind.mainGetMyId(),
        'Content-Type': 'application/json',
      };

  static Future<Uri> _uri(String path) async => Uri.parse(
      '${(await bind.mainGetApiServer()).replaceAll(RegExp(r'/+$'), '')}$path');

  static Future<http.Response> get(String path) async => http
      .get(await _uri(path), headers: await _headers())
      .timeout(const Duration(seconds: 10));

  static Future<http.Response> post(String path, Map<String, dynamic> body) async =>
      http
          .post(await _uri(path), headers: await _headers(), body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
}

/// Note une action au journal de la session (visible dans l'admin du site). Sans effet si l'API ne répond pas.
void ciLog(FFI ffi, String kind, [String? detail]) {
  CiTechApi.post('/api/v1/tech/log', {'peer': ffi.id, 'kind': kind, 'detail': detail})
      .catchError((_) => http.Response('', 0));
}

/// Passer le PC à un collègue : il le voit en tête de sa console et prend la main sans que le client
/// ait à accepter ; la session et le compteur continuent.
Future<void> ciHandoffDialog(FFI ffi) async {
  List<Map<String, dynamic>> colleagues = [];
  String? error;
  try {
    final res = await CiTechApi.get('/api/v1/tech/colleagues');
    if (res.statusCode == 200) {
      colleagues = ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['colleagues'] as List)
          .cast<Map<String, dynamic>>();
    } else {
      error = res.statusCode == 401
          ? 'Reconnectez-vous dans la console technicien.'
          : 'Liste des collègues indisponible (${res.statusCode}).';
    }
  } catch (_) {
    error = "Serveur d'assistance injoignable.";
  }
  String? selected;
  final note = TextEditingController();
  final ok = await ffi.dialogManager.show<bool>((setState, close, context) =>
      CustomAlertDialog(
        title: const Text('Passer à un collègue'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (error != null) Text(error),
            if (error == null && colleagues.isEmpty)
              const Text('Aucun autre poste technicien reconnu. Le collègue doit ouvrir une fois l\'app technicien.'),
            for (final c in colleagues)
              RadioListTile<String>(
                dense: true,
                value: c['id'] as String,
                groupValue: selected,
                onChanged: (v) => setState(() => selected = v),
                title: Text((c['name'] as String?) ?? (c['id'] as String)),
                subtitle: Text(c['online'] == true ? 'console ouverte' : 'console fermée',
                    style: TextStyle(
                        color: c['online'] == true ? const Color(0xFF15803D) : Colors.grey)),
              ),
            if (colleagues.isNotEmpty)
              TextField(
                controller: note,
                maxLength: 300,
                decoration: const InputDecoration(labelText: 'Message pour le collègue (facultatif)'),
              ),
            const Text('Il a 10 minutes pour prendre la main ; le client n\'aura pas à accepter.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
        actions: [
          dialogButton('Cancel', onPressed: close, isOutline: true),
          if (colleagues.isNotEmpty)
            dialogButton('OK', onPressed: selected == null ? null : () => close(true)),
        ],
        onCancel: close,
      ));
  if (ok != true || selected == null) return;
  try {
    final res = await CiTechApi.post('/api/v1/tech/handoff',
        {'peer': ffi.id, 'to': selected, 'note': note.text.trim()});
    if (res.statusCode == 200) {
      final to = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['to'];
      showToast('PC passé à $to : il a 10 min pour prendre la main.');
      await bind.sessionSendChat(
          sessionId: ffi.sessionId,
          text: 'Votre technicien passe la main à son collègue $to, qui va se connecter dans un instant.');
    } else {
      showToast(res.statusCode == 404
          ? 'Aucune session en cours notée sur ce PC : réessayez dans quelques secondes.'
          : 'Passage impossible (${res.statusCode}).');
    }
  } catch (_) {
    showToast("Serveur d'assistance injoignable.");
  }
}

/// Ouvre « Exécuter » (Win+R) chez le client et lance la commande.
Future<void> ciRunCommand(FFI ffi, String command) async {
  final sid = ffi.sessionId;
  await bind.sessionInputKey(
      sessionId: sid, name: 'VK_R', down: false, press: true,
      alt: false, ctrl: false, shift: false, command: true);
  await Future.delayed(_kTypingDelay);
  await bind.sessionInputString(sessionId: sid, value: command);
  await Future.delayed(const Duration(milliseconds: 250));
  await bind.sessionInputKey(
      sessionId: sid, name: 'VK_RETURN', down: false, press: true,
      alt: false, ctrl: false, shift: false, command: false);
}

Future<void> ciRunWithConfirm(FFI ffi, CiCommand c) async {
  if (c.confirm != null) {
    final ok = await ffi.dialogManager.show<bool>((setState, close, context) =>
        CustomAlertDialog(
          title: Text(c.label),
          content: Text(c.confirm!),
          actions: [
            dialogButton('Cancel', onPressed: close, isOutline: true),
            dialogButton('OK', onPressed: () => close(true)),
          ],
          onCancel: close,
          onSubmit: () => close(true),
        ));
    if (ok != true) return;
  }
  await ciRunCommand(ffi, c.command);
  ciLog(ffi, kCiPower.contains(c) ? 'power' : 'command', kCiPower.contains(c) ? c.label : c.command);
}

/// Mode « Tech uniquement » : clavier et souris du client bloqués pendant que le technicien travaille.
class CiTechMode {
  static final Map<String, Timer> _giveBack = {};

  static bool isOn(String id) => BlockInputState.find(id).value;

  static Future<void> set(FFI ffi, bool on, {bool notify = true}) async {
    _giveBack.remove(ffi.id)?.cancel();
    await bind.sessionToggleOption(
        sessionId: ffi.sessionId, value: on ? 'block-input' : 'unblock-input');
    BlockInputState.find(ffi.id).value = on;
    ciLog(ffi, 'tech_mode', on ? 'Mode Tech uniquement activé' : 'Mode Tech uniquement désactivé');
    if (notify) {
      await bind.sessionSendChat(
          sessionId: ffi.sessionId,
          text: on
              ? 'Votre technicien Concept Informatique travaille sur votre PC : clavier et souris sont '
                  'momentanément désactivés pour éviter les fausses manœuvres. Ils reviennent à la fin.'
              : 'Vous pouvez à nouveau utiliser votre clavier et votre souris.');
    }
  }

  /// Rend clavier et souris au client quelques minutes (taper un mot de passe…), puis rebloque.
  static Future<void> giveBack(FFI ffi, Duration duration) async {
    await set(ffi, false, notify: false);
    ciLog(ffi, 'give_back', 'Main rendue au client ${duration.inMinutes} min');
    await bind.sessionSendChat(
        sessionId: ffi.sessionId,
        text: 'Le technicien vous rend la main pendant ${duration.inMinutes} min : '
            'vous pouvez utiliser votre clavier et votre souris (par exemple pour taper un mot de passe).');
    _giveBack[ffi.id] = Timer(duration, () {
      _giveBack.remove(ffi.id);
      set(ffi, true);
    });
  }

  static bool isGivenBack(String id) => _giveBack.containsKey(id);
}
