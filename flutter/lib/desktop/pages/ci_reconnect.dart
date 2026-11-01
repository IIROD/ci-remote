// Concept Informatique (app client) : reconnexion du technicien après un redémarrage qu'il a demandé.
//
// Avant le redémarrage, l'app note le technicien et une échéance de 10 min (src/ci_remote.rs,
// option « ci-reconnect ») et se programme pour se relancer à l'ouverture de session. Au retour, la
// demande de connexion de CE technicien est acceptée une seule fois, s'il est aussi reconnu par le
// serveur comme poste technicien ; sinon le client accepte à la main, comme d'habitude.
//
// Même chose pour un collègue à qui le technicien a passé la session (F-18) : le serveur le confirme
// (GET /api/v1/device/handoff), 10 min au plus après le passage.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/ci_client_home.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';

const _kOption = 'ci-reconnect';

/// Technicien attendu après redémarrage, si l'échéance n'est pas passée.
String? ciReconnectPeer() {
  final parts = bind.mainGetLocalOption(key: _kOption).split('|');
  if (parts.length != 2) return null;
  final expires = int.tryParse(parts[1]) ?? 0;
  if (DateTime.now().millisecondsSinceEpoch ~/ 1000 > expires) return null;
  return parts[0];
}

class CiReconnectAccept extends StatefulWidget {
  final Client client;
  const CiReconnectAccept({Key? key, required this.client}) : super(key: key);

  @override
  State<CiReconnectAccept> createState() => _CiReconnectAcceptState();
}

class _CiReconnectAcceptState extends State<CiReconnectAccept> {
  bool _pending = false;
  String _message = 'Reconnexion du technicien après le redémarrage…';

  @override
  void initState() {
    super.initState();
    if (widget.client.authorized) return;
    final peer = ciReconnectPeer();
    if (peer != null && peer == widget.client.peerId) {
      _pending = true;
      _accept();
    } else {
      _handoff();
    }
  }

  /// Collègue annoncé par le technicien (passage de session) : accepté sans clic.
  Future<void> _handoff() async {
    try {
      final res = await CiDeviceApi.get(
          '/api/v1/device/handoff?peer=${Uri.encodeQueryComponent(widget.client.peerId)}');
      if (res.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      if (data['accept'] != true || !mounted) return;
      setState(() {
        _pending = true;
        _message = 'Votre technicien ${data['from'] ?? ''} a passé la main à son collègue.';
      });
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      setState(() => _pending = false);
      if (!widget.client.authorized && !widget.client.disconnected) {
        gFFI.serverModel.sendLoginResponse(widget.client, true);
      }
    } catch (_) {}
  }

  Future<void> _accept() async {
    bool verified = false;
    try {
      final res = await CiDeviceApi.get(
          '/api/v1/device/verify?peer=${Uri.encodeQueryComponent(widget.client.peerId)}');
      verified = res.statusCode == 200 &&
          (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['verified'] == true;
    } catch (_) {}
    bind.mainSetLocalOption(key: _kOption, value: ''); // une seule fois
    if (!mounted) return;
    setState(() => _pending = false);
    if (verified && !widget.client.authorized && !widget.client.disconnected) {
      gFFI.serverModel.sendLoginResponse(widget.client, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_pending) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(5, 0, 5, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFE6F6F4),
        border: Border.all(color: kCiBrand.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: kCiBrand)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_message,
              style: const TextStyle(color: kCiInk, fontSize: 12.5)),
        ),
      ]),
    );
  }
}
