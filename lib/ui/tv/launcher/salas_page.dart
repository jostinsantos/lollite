import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../../../data/models/repo_manifest.dart';
import '../../../data/services/party_service.dart';
import '../../../data/services/repo_manager.dart';
import '../repo/player/party_player.dart';
import '../widgets/focusable.dart';
import '../widgets/tv_keyboard.dart';

const _accent = Color(0xFFE50914);
const _bg = Color(0xFF0B0D12);
const _card = Color(0xFF161A22);
const _muted = Color(0x99FFFFFF);

/// Salas Party — UI TV (foco, sin AppBar, código con teclado QWERTY).
class TvSalasPage extends StatefulWidget {
  const TvSalasPage({super.key});

  @override
  State<TvSalasPage> createState() => _TvSalasPageState();
}

class _TvSalasPageState extends State<TvSalasPage> {
  final PartyService _party = PartyService.instance;
  List<PartyRoom> _rooms = [];
  bool _loading = true;
  String? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    await _party.init();
    await _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _party.listPublicRooms();
      if (!mounted) return;
      setState(() {
        _rooms = list;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _ensureUsername() async {
    if (_party.username != null && _party.username!.isNotEmpty) return;
    final name = await TvKeyboard.show(
      context,
      hint: 'Tu nombre',
      title: 'Nombre de usuario',
    );
    if (name != null && name.trim().isNotEmpty) {
      await _party.setUsername(name.trim());
    }
  }

  Future<void> _joinWithCode() async {
    await _ensureUsername();
    if (_party.username == null || _party.username!.isEmpty) return;
    final code = await TvKeyboard.show(
      context,
      hint: 'Código de sala',
      title: 'Unirse a sala',
    );
    if (code == null || code.trim().isEmpty) return;
    await _join(code.trim().toUpperCase());
  }

  Future<void> _join(String code) async {
    try {
      await _ensureUsername();
      final room = await _party.joinRoom(code);
      final repo = await _resolveRepo(room.repoId);
      if (repo == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Repo no instalado para esta sala')),
          );
        }
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TvPartyPlayerPage(room: room, repo: repo),
        ),
      );
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  Future<InstalledRepo?> _resolveRepo(String repoId) async {
    try {
      if (!mounted) return null;
      final repos = context.read<RepoManager>().installed;
      for (final r in repos) {
        if (r.manifest.id == repoId) return r;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _editUsername() async {
    final name = await TvKeyboard.show(
      context,
      initial: _party.username ?? '',
      hint: 'Tu nombre',
      title: 'Usuario Party',
    );
    if (name != null && name.trim().isNotEmpty) {
      await _party.setUsername(name.trim());
      setState(() {});
    }
  }

  List<PartyRoom> get _filtered {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return _rooms;
    return _rooms
        .where((r) =>
            r.title.toLowerCase().contains(q) ||
            r.code.toLowerCase().contains(q) ||
            r.hostUsername.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final rooms = _filtered;
    return Scaffold(
      backgroundColor: _bg,
      body: Focus(
        autofocus: true,
        onKeyEvent: (n, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.goBack ||
                  e.logicalKey == LogicalKeyboardKey.escape)) {
            Navigator.of(context).maybePop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 32, 48, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'Salas Party',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Focusable(
                    autofocus: true,
                    onTap: _editUsername,
                    builder: (f) => _chip(
                      f,
                      Icons.person,
                      _party.username?.isNotEmpty == true
                          ? _party.username!
                          : 'Usuario',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Focusable(
                    onTap: _joinWithCode,
                    builder: (f) => _chip(f, Icons.vpn_key_rounded, 'Código'),
                  ),
                  const SizedBox(width: 12),
                  Focusable(
                    onTap: _refresh,
                    builder: (f) => _chip(f, Icons.refresh, 'Actualizar'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Salas públicas en vivo · OK para unirse · Atrás para salir',
                style: TextStyle(color: _muted, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(color: _accent))
                    : _error != null
                        ? Center(
                            child: Text(_error!,
                                style:
                                    const TextStyle(color: Colors.white70)))
                        : rooms.isEmpty
                            ? const Center(
                                child: Text(
                                  'No hay salas públicas ahora',
                                  style: TextStyle(color: _muted),
                                ),
                              )
                            : GridView.builder(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 16,
                                  crossAxisSpacing: 16,
                                  childAspectRatio: 1.6,
                                ),
                                itemCount: rooms.length,
                                itemBuilder: (context, i) {
                                  final r = rooms[i];
                                  return Focusable(
                                    onTap: () => _join(r.code),
                                    builder: (f) => AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 120),
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: _card,
                                        borderRadius:
                                            BorderRadius.circular(14),
                                        border: Border.all(
                                          color: f ? _accent : Colors.white12,
                                          width: f ? 3 : 1,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            r.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            'Host: ${r.hostUsername}',
                                            style: const TextStyle(
                                                color: _muted, fontSize: 12),
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            children: [
                                              Text(
                                                r.code,
                                                style: const TextStyle(
                                                  color: _accent,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: 2,
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                '${r.memberCount}/${r.maxMembers}',
                                                style: const TextStyle(
                                                    color: Colors.white70),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(bool focused, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: focused ? _accent : Colors.white10,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: focused ? Colors.white : Colors.transparent, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}
