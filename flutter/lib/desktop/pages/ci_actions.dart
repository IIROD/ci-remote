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

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

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
