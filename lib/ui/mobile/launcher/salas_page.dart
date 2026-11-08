import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../../data/services/party_service.dart';
import '../../../data/services/repo_manager.dart';
import '../repo/player/party_player.dart';

const _bg = Color(0xFF0B0D10);
const _card = Color(0xFF161A22);
const _border = Color(0xFF1E2430);
const _accent = Color(0xFFE50914);
const _muted = Color(0x99FFFFFF);

class MobileSalasPage extends StatefulWidget {
  const MobileSalasPage({super.key});

  @override
  State<MobileSalasPage> createState() => _MobileSalasPageState();
}

class _MobileSalasPageState extends State<MobileSalasPage> {
  final _codeCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  List<PartyRoom> _rooms = [];
  List<PartyRoom> _myRooms = [];
  bool _loading = true;
  String? _error;
  bool _editingUsername = false;
  String _filterType = 'all';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await PartyService.instance.init();
      final u = PartyService.instance.username;
      if (u != null && u.isNotEmpty) _usernameCtrl.text = u;
      await _refresh();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refresh() async {
    try {
      final list =
          await PartyService.instance.listPublicRooms(query: _searchCtrl.text);
      List<PartyRoom> mine = [];
      try {
        mine = await PartyService.instance.listMyRooms();
      } catch (_) {}
      if (mounted) setState(() {
        _rooms = list;
        _myRooms = mine;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  List<PartyRoom> get _filtered {
    var list = _rooms;
    if (_filterType == 'movie') {
      list = list
          .where((r) =>
              r.contentType.toLowerCase().contains('movie') ||
              r.contentType.toLowerCase().contains('pelicul'))
          .toList();
    } else if (_filterType == 'series') {
      list = list
          .where((r) =>
              r.contentType.toLowerCase().contains('series') ||
              r.contentType.toLowerCase().contains('tv') ||
              r.season != null)
          .toList();
    }
    return list;
  }

  Future<void> _saveUsername() async {
    try {
      await PartyService.instance.setUsername(_usernameCtrl.text);
      setState(() => _editingUsername = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _join(String code) async {
    if (PartyService.instance.username == null ||
        PartyService.instance.username!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Elige un nombre de usuario primero')),
      );
      return;
    }
    try {
      final room = await PartyService.instance.joinRoom(code);
      if (!mounted) return;
      _open(room);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('StateError: ', ''))),
      );
    }
  }

  void _open(PartyRoom room) {
    final repos = context.read<RepoManager>().installed;
    final repo = repos.where((r) => r.manifest.id == room.repoId).firstOrNull;
    if (repo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Instala el repositorio de este contenido primero')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobilePartyPlayerPage(room: room, repo: repo),
      ),
    );
  }

  String _elapsed(PartyRoom r) {
    final d = DateTime.now().difference(r.createdAt);
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _usernameCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final party = PartyService.instance;
    final hasUser = party.username != null && party.username!.isNotEmpty;
    final filtered = _filtered;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Salas Party'),
        actions: [
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _loading
                ? null
                : () async {
                    setState(() => _loading = true);
                    await _refresh();
                    if (mounted) setState(() => _loading = false);
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          // Username
          Row(
            children: [
              const Icon(Icons.person, color: _muted, size: 20),
              const SizedBox(width: 8),
              if (!_editingUsername && hasUser)
                Expanded(
                    child: Text('Tu nombre: ${party.username}',
                        style: const TextStyle(color: Colors.white70)))
              else
                Expanded(
                  child: TextField(
                    controller: _usernameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Nombre de usuario',
                      hintStyle: TextStyle(color: _muted),
                      isDense: true,
                    ),
                    maxLength: 24,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[a-zA-Z0-9_\-áéíóúÁÉÍÓÚñÑ ]')),
                    ],
                  ),
                ),
              if (_editingUsername || !hasUser)
                TextButton(onPressed: _saveUsername, child: const Text('Guardar'))
              else
                TextButton(
                    onPressed: () => setState(() => _editingUsername = true),
                    child: const Text('Cambiar')),
            ],
          ),
          const SizedBox(height: 12),
          // Code join
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeCtrl,
                  style: const TextStyle(
                      color: Colors.white,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700),
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: 'Código de sala',
                    hintStyle: const TextStyle(
                        color: _muted, letterSpacing: 0, fontWeight: FontWeight.normal),
                    filled: true,
                    fillColor: _card,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border)),
                  ),
                  onSubmitted: (_) => _join(_codeCtrl.text),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _join(_codeCtrl.text),
                child: const Text('Unirse'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Buscar título, host o código…',
              hintStyle: const TextStyle(color: _muted),
              prefixIcon: const Icon(Icons.search, color: _muted),
              filled: true,
              fillColor: _card,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _border)),
            ),
            onSubmitted: (_) async {
              setState(() => _loading = true);
              await _refresh();
              if (mounted) setState(() => _loading = false);
            },
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final e in [
                ('all', 'Todo'),
                ('movie', 'Películas'),
                ('series', 'Series')
              ])
                ChoiceChip(
                  label: Text(e.$2),
                  selected: _filterType == e.$1,
                  onSelected: (_) => setState(() => _filterType = e.$1),
                  selectedColor: _accent.withValues(alpha: 0.3),
                  labelStyle: TextStyle(
                      color: _filterType == e.$1 ? _accent : Colors.white70),
                  backgroundColor: _card,
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Salas públicas (${filtered.length})',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 8),
          if (_loading && _rooms.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null && _rooms.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: const TextStyle(color: _muted), textAlign: TextAlign.center),
            )
          else if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No hay salas públicas.\nCrea una desde el reproductor (botón Party).',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted),
              ),
            )
          else
            ...filtered.map((room) {
              final ep = room.season != null && room.episode != null
                  ? 'T${room.season} E${room.episode}'
                  : null;
              return Card(
                color: _card,
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: room.poster != null
                        ? CachedNetworkImage(
                            imageUrl: room.poster!,
                            width: 44,
                            height: 64,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                                width: 44, height: 64, color: Colors.white10),
                          )
                        : Container(width: 44, height: 64, color: Colors.white10),
                  ),
                  title: Text(room.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    [
                      if (ep != null) ep,
                      '${room.memberCount}/${room.maxMembers}',
                      'Lleva ${_elapsed(room)}',
                      room.hostUsername,
                      room.code,
                    ].join(' · '),
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
                  trailing: FilledButton(
                    onPressed: () => _join(room.code),
                    style: FilledButton.styleFrom(backgroundColor: _accent),
                    child: const Text('Unirse'),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
