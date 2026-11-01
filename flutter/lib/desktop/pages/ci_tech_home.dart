// Concept Informatique : page d'accueil de l'app technicien (F-15).
//
// Connexion avec un compte admin du site (mot de passe + code reçu par email), puis tableau des PC
// clients : tri, recherche, demandes d'aide en tête, « Prendre la main ». Le jeton (12 h) est délivré
// par le site (ajax/assist-tech-login.php) ; les données viennent de l'API d'assistance.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/ci_client_home.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;

const kCiSiteUrl = 'https://www.conceptinformatique.be';
const _kToken = 'ci-tech-token';
const _kExpires = 'ci-tech-expires';
const _kName = 'ci-tech-name';

class CiTechHome extends StatefulWidget {
  const CiTechHome({Key? key}) : super(key: key);

  @override
  State<CiTechHome> createState() => _CiTechHomeState();
}

class _CiTechHomeState extends State<CiTechHome> {
  String _token = '';
  String _name = '';
  String? _loginNotice;

  @override
  void initState() {
    super.initState();
    final expires =
        double.tryParse(bind.mainGetLocalOption(key: _kExpires)) ?? 0;
    if (expires > DateTime.now().millisecondsSinceEpoch / 1000 + 60) {
      _token = bind.mainGetLocalOption(key: _kToken);
      _name = bind.mainGetLocalOption(key: _kName);
    }
  }

  void _signedIn(String token, double expires, String name) {
    bind.mainSetLocalOption(key: _kToken, value: token);
    bind.mainSetLocalOption(key: _kExpires, value: expires.toString());
    bind.mainSetLocalOption(key: _kName, value: name);
    setState(() {
      _token = token;
      _name = name;
      _loginNotice = null;
    });
  }

  void _signOut([String? notice]) {
    bind.mainSetLocalOption(key: _kToken, value: '');
    bind.mainSetLocalOption(key: _kExpires, value: '');
    setState(() {
      _token = '';
      _loginNotice = notice;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ciTheme(),
      child: Container(
        color: kCiBg,
        child: _token.isEmpty
            ? _CiTechLogin(onSignedIn: _signedIn, notice: _loginNotice)
            : _CiTechConsole(token: _token, name: _name, onSignOut: _signOut),
      ),
    );
  }
}

// ==================== connexion ====================

class _CiTechLogin extends StatefulWidget {
  final void Function(String token, double expires, String name) onSignedIn;
  final String? notice;
  const _CiTechLogin({required this.onSignedIn, this.notice});

  @override
  State<_CiTechLogin> createState() => _CiTechLoginState();
}

class _CiTechLoginState extends State<_CiTechLogin> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  String? _challenge;
  String _maskedEmail = '';
  bool _totp = false;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = _challenge == null
        ? {'email': _email.text.trim(), 'password': _password.text}
        : {'challenge': _challenge, 'code': _code.text.trim()};
    try {
      final res = await http
          .post(Uri.parse('$kCiSiteUrl/ajax/assist-tech-login.php'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      final Map<String, dynamic> data;
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      } on FormatException {
        setState(() {
          _error =
              'Réponse inattendue du site (code ${res.statusCode}). Réessayez plus tard.';
          _busy = false;
        });
        return;
      }
      if (res.statusCode == 200 && data['token'] is String) {
        widget.onSignedIn(
            data['token'] as String,
            (data['expires'] as num).toDouble(),
            (data['name'] as String?) ?? '');
        return;
      }
      if (res.statusCode == 200 && data['need_code'] == true) {
        _password.clear();
        setState(() {
          _challenge = data['challenge'] as String;
          _maskedEmail = (data['email'] as String?) ?? '';
          _totp = data['method'] == 'totp';
        });
      } else {
        if (data['restart'] == true) _challenge = null;
        _error = (data['error'] as String?) ?? 'Connexion refusée.';
      }
    } catch (_) {
      _error =
          'Impossible de joindre le site. Vérifiez la connexion à Internet.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final step2 = _challenge != null;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFE6F6F4), kCiBg],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 420,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x1A0F172A),
                      blurRadius: 32,
                      offset: Offset(0, 12)),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(height: 5, color: kCiBrand),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(36, 30, 36, 30),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Image.asset('assets/ci_logo.png',
                                height: 70,
                                filterQuality: FilterQuality.medium),
                            const SizedBox(height: 22),
                            Text(step2 ? 'Vérification' : 'Console technicien',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: kCiInk,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            Text(
                                step2
                                    ? (_totp
                                        ? 'Saisissez le code à 6 chiffres affiché\npar Google Authenticator'
                                        : 'Saisissez le code à 6 chiffres envoyé à\n$_maskedEmail')
                                    : 'Connectez-vous avec votre compte administrateur du site.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: kCiMuted,
                                    fontSize: 14,
                                    height: 1.4)),
                            const SizedBox(height: 26),
                            if (widget.notice != null && !step2) ...[
                              _message(widget.notice!, warning: true),
                              const SizedBox(height: 16),
                            ],
                            if (!step2) ...[
                              TextField(
                                controller: _email,
                                autofocus: true,
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                    labelText: 'Adresse email',
                                    prefixIcon:
                                        Icon(Icons.mail_outline, size: 20)),
                              ),
                              const SizedBox(height: 14),
                              TextField(
                                controller: _password,
                                obscureText: !_showPassword,
                                onSubmitted: (_) => _busy ? null : _submit(),
                                decoration: InputDecoration(
                                  labelText: 'Mot de passe',
                                  prefixIcon:
                                      const Icon(Icons.lock_outline, size: 20),
                                  suffixIcon: IconButton(
                                    tooltip:
                                        _showPassword ? 'Masquer' : 'Afficher',
                                    icon: Icon(
                                        _showPassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        size: 20),
                                    onPressed: () => setState(
                                        () => _showPassword = !_showPassword),
                                  ),
                                ),
                              ),
                            ] else
                              TextField(
                                controller: _code,
                                autofocus: true,
                                maxLength: 6,
                                keyboardType: TextInputType.number,
                                onSubmitted: (_) => _busy ? null : _submit(),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 28,
                                    letterSpacing: 10,
                                    fontWeight: FontWeight.w600),
                                decoration: const InputDecoration(
                                    hintText: '••••••', counterText: ''),
                              ),
                            if (_error != null) ...[
                              const SizedBox(height: 16),
                              _message(_error!),
                            ],
                            const SizedBox(height: 22),
                            SizedBox(
                              height: 48,
                              child: ElevatedButton(
                                onPressed: _busy ? null : _submit,
                                child: _busy
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white))
                                    : Text(
                                        step2
                                            ? 'Valider le code'
                                            : 'Se connecter',
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600)),
                              ),
                            ),
                            if (step2) ...[
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => setState(() {
                                          _challenge = null;
                                          _code.clear();
                                          _error = null;
                                        }),
                                child: const Text('Changer de compte'),
                              ),
                            ],
                          ]),
                    ),
                  ]),
            ),
            const SizedBox(height: 18),
            const Text('Accès réservé aux techniciens de Concept Informatique',
                style: TextStyle(color: kCiMuted, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Widget _message(String text, {bool warning = false}) {
    final color = warning ? const Color(0xFFB45309) : const Color(0xFFB91C1C);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: warning ? const Color(0xFFFFFBEB) : const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(warning ? Icons.info_outline : Icons.error_outline,
            color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: TextStyle(color: color, fontSize: 13, height: 1.35))),
      ]),
    );
  }
}

// ==================== parc des PC ====================

class _CiTechConsole extends StatefulWidget {
  final String token;
  final String name;
  final void Function([String? notice]) onSignOut;
  const _CiTechConsole(
      {required this.token, required this.name, required this.onSignOut});

  @override
  State<_CiTechConsole> createState() => _CiTechConsoleState();
}

class _CiTechConsoleState extends State<_CiTechConsole> {
  Timer? _timer;
  List<Map<String, dynamic>> _devices = [];
  double _serverTime = 0;
  String? _error;
  bool _loaded = false;
  String _query = '';
  int _sortColumn = 0;
  bool _sortAsc = true;
  String _myId = '';
  final _connectCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    bind.mainGetMyId().then((id) {
      _myId = id;
      _timer = periodic_immediate(const Duration(seconds: 10), _load);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connectCtrl.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _headers() async => {
        'Authorization': 'Bearer ${widget.token}',
        'X-CI-Device': _myId,
        'Content-Type': 'application/json'
      };

  Future<String> _base() async =>
      (await bind.mainGetApiServer()).replaceAll(RegExp(r'/+$'), '');

  Future<void> _load() async {
    try {
      final res = await http
          .get(Uri.parse('${await _base()}/api/v1/tech/devices'),
              headers: await _headers())
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 401) {
        _timer?.cancel();
        widget.onSignOut('Session expirée : reconnectez-vous.');
        return;
      }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _devices = (data['devices'] as List).cast<Map<String, dynamic>>();
        _serverTime = (data['server_time'] as num?)?.toDouble() ?? 0;
        _error = null;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            "Serveur d'assistance injoignable : nouvel essai dans 10 s.");
      }
    }
  }

  Future<void> _closeHelp(int id) async {
    try {
      await http
          .post(Uri.parse('${await _base()}/api/v1/tech/help/done'),
              headers: await _headers(), body: jsonEncode({'id': id}))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
    await _load();
  }

  void _connect(String id) {
    final clean = id.replaceAll(RegExp(r'\s'), '');
    if (clean.isNotEmpty) connect(context, clean);
  }

  static String _clientOf(Map<String, dynamic> d) {
    final name = [d['first_name'], d['last_name']]
        .where((v) => v is String && v.isNotEmpty)
        .join(' ');
    return name.isNotEmpty ? name : ((d['account_label'] as String?) ?? '');
  }

  String _ago(num? ts) {
    if (ts == null) return '—';
    final s = (_serverTime - ts).round();
    if (s < 60) return "à l'instant";
    if (s < 3600) return 'il y a ${s ~/ 60} min';
    if (s < 86400) return 'il y a ${s ~/ 3600} h';
    final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  List<Map<String, dynamic>> get _rows {
    final q = _query.trim().toLowerCase();
    final rows = _devices.where((d) {
      if (q.isEmpty) return true;
      return [
        _clientOf(d),
        d['owner'],
        d['hostname'],
        d['username'],
        d['id'],
        d['email'],
        d['phone']
      ].whereType<String>().any((v) => v.toLowerCase().contains(q));
    }).toList();
    Comparable key(Map<String, dynamic> d) => switch (_sortColumn) {
          0 => (d['help'] != null ? 0 : 2) + (d['online'] == true ? 0 : 1),
          1 => _clientOf(d).toLowerCase(),
          2 => ((d['owner'] as String?) ?? '').toLowerCase(),
          3 => ((d['hostname'] as String?) ?? '').toLowerCase(),
          4 => (d['id'] as String?) ?? '',
          _ => -((d['last_seen'] as num?) ?? 0),
        } as Comparable;
    rows.sort((a, b) {
      final c = key(a).compareTo(key(b));
      return _sortAsc ? c : -c;
    });
    return rows;
  }

  void _sort(int column, bool asc) => setState(() {
        _sortColumn = column;
        _sortAsc = asc;
      });

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final online = _devices.where((d) => d['online'] == true).length;
    final helps = _devices.where((d) => d['help'] != null).length;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _header(online, helps, box.maxWidth),
        _toolbar(wide),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_error!,
                style: const TextStyle(color: Color(0xFFB45309), fontSize: 13)),
          ),
        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty
                  ? const Center(
                      child: Text('Aucun PC ne correspond.',
                          style: TextStyle(color: kCiMuted)))
                  : (wide ? _table(rows) : _cards(rows)),
        ),
      ]);
    });
  }

  Widget _header(int online, int helps, double width) {
    final compact = width < 640;
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: compact ? 12 : 16, vertical: 10),
      decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: kCiBrand, width: 3))),
      child: Row(children: [
        Image.asset('assets/ci_logo.png', height: compact ? 28 : 36),
        if (width >= 560) ...[
          const SizedBox(width: 12),
          const Text('Console technicien',
              style: TextStyle(
                  color: kCiInk, fontSize: 16, fontWeight: FontWeight.w700)),
        ],
        const Spacer(),
        _kpi('$online/${_devices.length}', compact ? '' : 'en ligne', kCiBrand),
        const SizedBox(width: 12),
        _kpi('$helps', compact ? '' : "demande${helps > 1 ? 's' : ''} d'aide",
            helps > 0 ? const Color(0xFFDC2626) : kCiMuted,
            icon: compact ? Icons.support_agent : null),
        if (!compact) ...[
          const SizedBox(width: 16),
          Text(widget.name,
              style: const TextStyle(color: kCiMuted, fontSize: 13)),
        ],
        IconButton(
          tooltip: 'Se déconnecter (${widget.name})',
          icon: const Icon(Icons.logout, color: kCiMuted),
          onPressed: () => widget.onSignOut(),
        ),
      ]),
    );
  }

  Widget _toolbar(bool wide) {
    final search = TextField(
      onChanged: (v) => setState(() => _query = v),
      decoration: const InputDecoration(
        isDense: true,
        prefixIcon: Icon(Icons.search, size: 20),
        hintText: 'Rechercher : client, propriétaire, PC, ID, email…',
      ),
    );
    final join = Row(
        mainAxisSize: wide ? MainAxisSize.min : MainAxisSize.max,
        children: [
          SizedBox(
            width: wide ? 170 : null,
            child: wide ? _idField() : null,
          ),
          if (!wide) Expanded(child: _idField()),
          const SizedBox(width: 8),
          SizedBox(
            height: 44,
            child: ElevatedButton(
                onPressed: () => _connect(_connectCtrl.text),
                child: const Text('Joindre')),
          ),
        ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: wide
          ? Row(children: [
              Expanded(child: search),
              const SizedBox(width: 12),
              join
            ])
          : Column(children: [search, const SizedBox(height: 8), join]),
    );
  }

  Widget _idField() => TextField(
        controller: _connectCtrl,
        onSubmitted: _connect,
        decoration:
            const InputDecoration(isDense: true, hintText: 'ID à joindre'),
      );

  Widget _kpi(String value, String label, Color color, {IconData? icon}) =>
      Row(children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 3)
        ],
        Text(value,
            style: TextStyle(
                color: color, fontSize: 16, fontWeight: FontWeight.w700)),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: kCiMuted, fontSize: 12)),
        ],
      ]);

  // ---------- grand écran : tableau à la largeur de la fenêtre ----------

  static const _columns = [
    ('ÉTAT', 2),
    ('CLIENT', 4),
    ('PROPRIÉTAIRE', 2),
    ('PC', 3),
    ('ID', 2),
    ('VU', 2)
  ];

  Widget _table(List<Map<String, dynamic>> rows) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: kCiLine),
          borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: const Color(0xFFF8FAFC),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            for (var i = 0; i < _columns.length; i++)
              Expanded(
                  flex: _columns[i].$2, child: _headerCell(i, _columns[i].$1)),
            const SizedBox(width: 250),
          ]),
        ),
        const Divider(height: 1, color: kCiLine),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: kCiLine),
            itemBuilder: (_, i) => _tableRow(rows[i]),
          ),
        ),
      ]),
    );
  }

  Widget _headerCell(int index, String label) {
    final active = _sortColumn == index;
    return InkWell(
      onTap: () => _sort(index, active ? !_sortAsc : true),
      child: Row(children: [
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: active ? kCiInk : kCiMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .3)),
        ),
        if (active)
          Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14, color: kCiInk),
      ]),
    );
  }

  Widget _cell(int flex, Widget child) => Expanded(
      flex: flex,
      child: Padding(padding: const EdgeInsets.only(right: 10), child: child));

  Text _text(String? v, {TextStyle? style}) =>
      Text((v == null || v.isEmpty) ? '—' : v,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: style);

  Widget _tableRow(Map<String, dynamic> d) {
    final help = d['help'] as Map<String, dynamic>?;
    final contact = _contactOf(d);
    return Container(
      color: help != null ? const Color(0xFFFEF2F2) : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        _cell(2, _status(d)),
        _cell(
            4,
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _text(_clientOf(d),
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, color: kCiInk)),
                  if (contact.isNotEmpty)
                    _text(contact,
                        style: const TextStyle(color: kCiMuted, fontSize: 12)),
                  if (help != null) _helpText(help),
                ])),
        _cell(2, _text(d['owner'] as String?)),
        _cell(3, _text(_pcOf(d))),
        _cell(
            2,
            _text(d['id'] as String?,
                style: const TextStyle(fontFamily: 'monospace'))),
        _cell(
            2,
            _text(_ago(d['last_seen'] as num?),
                style: const TextStyle(color: kCiMuted))),
        SizedBox(width: 250, child: _actions(d, help, alignEnd: true)),
      ]),
    );
  }

  // ---------- petit écran : une carte par PC ----------

  Widget _cards(List<Map<String, dynamic>> rows) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final d = rows[i];
        final help = d['help'] as Map<String, dynamic>?;
        final contact = _contactOf(d);
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: help != null ? const Color(0xFFFEF2F2) : Colors.white,
            border: Border.all(
                color: help != null ? const Color(0xFFFCA5A5) : kCiLine),
            borderRadius: BorderRadius.circular(12),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: _text(_clientOf(d),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: kCiInk))),
              _status(d),
            ]),
            const SizedBox(height: 4),
            _text(
                [
                  _pcOf(d),
                  if ((d['owner'] as String? ?? '').isNotEmpty)
                    'à ${d['owner']}'
                ].join(' · '),
                style: const TextStyle(color: kCiInk)),
            if (contact.isNotEmpty)
              _text(contact,
                  style: const TextStyle(color: kCiMuted, fontSize: 12)),
            _text('ID ${d['id']} · vu ${_ago(d['last_seen'] as num?)}',
                style: const TextStyle(color: kCiMuted, fontSize: 12)),
            if (help != null) ...[
              const SizedBox(height: 6),
              _helpText(help, lines: 3)
            ],
            const SizedBox(height: 10),
            _actions(d, help, alignEnd: false),
          ]),
        );
      },
    );
  }

  // ---------- éléments communs ----------

  static String _pcOf(Map<String, dynamic> d) => [
        (d['hostname'] as String?) ?? '?',
        if (d['username'] != null) '(${d['username']})'
      ].join(' ');

  static String _contactOf(Map<String, dynamic> d) {
    final email = (d['email'] as String?) ?? '';
    final phone = (d['phone'] as String?) ?? '';
    return [email, if (phone.isNotEmpty && phone != email) phone]
        .where((v) => v.isNotEmpty)
        .join(' · ');
  }

  Widget _status(Map<String, dynamic> d) {
    final online = d['online'] == true;
    final session = d['session'] as String?;
    final color = session != null
        ? kCiBrand
        : (online ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
            session != null
                ? 'en session ($session)'
                : (online ? 'en ligne' : 'hors ligne'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
      ),
    ]);
  }

  Widget _helpText(Map<String, dynamic> help, {int lines = 2}) => Text(
        "🆘 ${(help['message'] as String?) ?? "Demande d'aide"}",
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 12),
      );

  Widget _actions(Map<String, dynamic> d, Map<String, dynamic>? help,
      {required bool alignEnd}) {
    final online = d['online'] == true;
    final id = (d['id'] as String?) ?? '';
    final take = ElevatedButton.icon(
      icon: const Icon(Icons.mouse, size: 16),
      label: const Text('Prendre la main'),
      onPressed: online ? () => _connect(id) : null,
    );
    return Row(
      mainAxisAlignment:
          alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (alignEnd)
          take
        else
          Expanded(child: SizedBox(height: 40, child: take)),
        if (help != null) ...[
          const SizedBox(width: 6),
          OutlinedButton(
              onPressed: () => _closeHelp(help['id'] as int),
              child: const Text('Traitée')),
        ],
      ],
    );
  }
}
