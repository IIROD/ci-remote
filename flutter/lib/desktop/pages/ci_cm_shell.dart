// Concept Informatique (app client) : fenêtre de connexion compacte pendant la session.
//
// La fenêtre RustDesk (permissions, discussion, boutons) cachait une partie de l'écran. Une fois la
// demande acceptée, elle devient une petite carte en haut à droite : technicien (son nom, pas celui de
// son PC), compteur de temps, boutons « Détails » et « Terminer ». « Détails » rouvre la fenêtre
// complète ; une nouvelle demande de connexion l'ouvre aussi. La fenêtre est exclue de la capture
// (src/ci_overlay.rs) : seul le client la voit, pas le technicien.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/ci_client_home.dart';
import 'package:flutter_hbb/desktop/pages/ci_session_counter.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

const _kCompactSize = Size(340, 236);
const _kFullSize = Size(320, 620);

class CiCmShell extends StatefulWidget {
  final Widget child;
  const CiCmShell({Key? key, required this.child}) : super(key: key);

  @override
  State<CiCmShell> createState() => _CiCmShellState();
}

class _CiCmShellState extends State<CiCmShell> {
  bool _expanded = false;
  final _alwaysObserved = 0.obs; // Obx exige au moins une valeur observée à chaque construction
  bool? _compactApplied;
  static final Map<String, String> _techNames = {};

  void _applySize(bool compact) {
    if (_compactApplied == compact) return;
    _compactApplied = compact;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.setSizeAlignment(
          compact ? _kCompactSize : _kFullSize, Alignment.topRight);
      if (compact) await windowManager.setAlwaysOnTop(true);
    });
  }

  Future<void> _loadTechName(String peerId) async {
    if (_techNames.containsKey(peerId)) return;
    _techNames[peerId] = '';
    try {
      final res = await CiDeviceApi.get(
          '/api/v1/device/verify?peer=${Uri.encodeQueryComponent(peerId)}');
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        if (data['verified'] == true && mounted) {
          setState(() => _techNames[peerId] = (data['name'] as String?) ?? '');
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ServerModel>(builder: (context, model, _) => Obx(() {
      _alwaysObserved.value;
      final unread = model.clients.fold<int>(0, (n, c) => n + c.unreadChatMessageCount.value);
      final active =
          model.clients.where((c) => c.authorized && !c.disconnected).toList();
      final pending = model.clients.any((c) => !c.authorized && !c.disconnected);
      // Message du technicien : la discussion s'ouvre (fenêtre complète) pour que le client le lise.
      if (!_expanded && unread > 0 && active.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _expanded = true);
        });
      }
      final compact = active.isNotEmpty && !pending && !_expanded;
      _applySize(compact);
      if (!compact) {
        return Column(children: [
          if (active.isNotEmpty && !pending)
            Material(
              color: kCiBrand,
              child: InkWell(
                onTap: () => setState(() => _expanded = false),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.unfold_less, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text('Réduire la fenêtre',
                        style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          Expanded(child: widget.child),
        ]);
      }
      final client = active.first;
      _loadTechName(client.peerId);
      final tech = _techNames[client.peerId] ?? '';
      return Theme(
        data: ciTheme(),
        child: Material(
          color: kCiBg,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(color: Color(0xFF16A34A), shape: BoxShape.circle)),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    tech.isNotEmpty ? '$tech vous aide' : 'Technicien connecté',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kCiInk, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                if (tech.isNotEmpty)
                  const Tooltip(
                      message: 'Technicien vérifié — Concept Informatique',
                      child: Icon(Icons.verified_user, color: Color(0xFF15803D), size: 17)),
              ]),
              const SizedBox(height: 6),
              const CiClientCounter(),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => setState(() => _expanded = true),
                    icon: const Icon(Icons.unfold_more, size: 16),
                    label: const Text('Détails'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        foregroundColor: kCiBrandDark,
                        side: const BorderSide(color: kCiLine)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _end(model, client),
                    icon: const Icon(Icons.call_end, size: 16),
                    label: const Text('Terminer'),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        backgroundColor: const Color(0xFFDC2626),
                        foregroundColor: Colors.white),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      );
    }));
  }

  Future<void> _end(ServerModel model, Client client) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Terminer l\'assistance ?'),
        content: const Text('Le technicien sera déconnecté.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Terminer')),
        ],
      ),
    );
    if (ok == true) bind.cmCloseConnection(connId: client.id);
  }
}
