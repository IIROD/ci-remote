// Concept Informatique : « technicien vérifié » (F-16), affiché au client quand quelqu'un demande
// à se connecter. Anti-arnaque : seuls nos postes techniciens (connectés à l'app technicien avec un
// compte admin du site, révocables) sont reconnus.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/ci_client_home.dart';

class CiPeerCheck extends StatefulWidget {
  final String peerId;
  const CiPeerCheck({Key? key, required this.peerId}) : super(key: key);

  @override
  State<CiPeerCheck> createState() => _CiPeerCheckState();
}

class _CiPeerCheckState extends State<CiPeerCheck> {
  static final Map<String, Future<Map<String, dynamic>?>> _cache = {};

  static Future<Map<String, dynamic>?> _verify(String peerId) async {
    try {
      final res = await CiDeviceApi.get(
          '/api/v1/device/verify?peer=${Uri.encodeQueryComponent(peerId)}');
      if (res.statusCode != 200) return null;
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final future =
        _cache.putIfAbsent(widget.peerId, () => _verify(widget.peerId));
    return FutureBuilder<Map<String, dynamic>?>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _box(Icons.hourglass_top, const Color(0xFF64748B),
              const Color(0xFFF1F5F9), 'Vérification du technicien…', null);
        }
        final data = snap.data;
        if (data == null) {
          _cache.remove(widget.peerId); // nouvel essai à la prochaine demande
          return _box(
              Icons.help_outline,
              const Color(0xFFB45309),
              const Color(0xFFFFFBEB),
              'Vérification impossible',
              "En cas de doute, refusez et appelez-nous au $kCiShopPhone.");
        }
        if (data['verified'] == true) {
          final name = (data['name'] as String?) ?? '';
          return _box(
              Icons.verified_user,
              const Color(0xFF15803D),
              const Color(0xFFF0FDF4),
              'Technicien vérifié — Concept Informatique',
              name.isEmpty ? null : name);
        }
        return _box(
            Icons.gpp_bad,
            const Color(0xFFB91C1C),
            const Color(0xFFFEF2F2),
            "Ce n'est PAS un technicien Concept Informatique",
            "Si quelqu'un vous a appelé pour vous demander d'accepter, refusez et appelez-nous au $kCiShopPhone.");
      },
    );
  }

  Widget _box(
          IconData icon, Color color, Color bg, String title, String? detail) =>
      Container(
        margin: const EdgeInsets.fromLTRB(5, 0, 5, 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: color.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.w700, fontSize: 13)),
              if (detail != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(detail,
                      style: const TextStyle(
                          color: Color(0xFF1E293B), fontSize: 12)),
                ),
            ]),
          ),
        ]),
      );
}
