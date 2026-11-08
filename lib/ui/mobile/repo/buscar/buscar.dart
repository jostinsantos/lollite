import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../widgets/focusable.dart';
import '../../repo/contenido/contenido.dart';

class RepoSearchPage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoSearchPage({super.key, required this.repo});
  @override
  State<RepoSearchPage> createState() => _RepoSearchPageState();
}

class _RepoSearchPageState extends State<RepoSearchPage> {
  final _controller = TextEditingController();
  List<ContentItem> _results = [];
  bool _loading = false;

  // Historial de búsquedas recientes (persistente por repo)
  List<String> _history = [];

  String get _repoId => widget.repo.manifest.id;

  bool get _useBackdrop =>
      widget.repo.manifest.searchImageStyle == 'backdrop';

  bool get _showTitle => widget.repo.manifest.searchShowTitle;

  /// true si el campo está vacío y no hay resultados activos
  bool get _showingHistory => _controller.text.trim().isEmpty && !_loading;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHistory());
  }

  void _loadHistory() {
    if (!mounted) return;
    final prefs = context.read<RepoPrefs>();
    setState(() {
      _history = List<String>.from(prefs.searchHistory(_repoId));
    });
  }

  Future<void> _persistHistory() async {
    if (!mounted) return;
    await context.read<RepoPrefs>().setSearchHistory(_repoId, _history);
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
      });
      return;
    }

    // Guardar en historial (sin duplicados, más reciente primero)
    setState(() {
      _history.remove(query);
      _history.insert(0, query);
      if (_history.length > RepoPrefs.maxSearchHistory) {
        _history = _history.take(RepoPrefs.maxSearchHistory).toList();
      }
    });
    await _persistHistory();

    setState(() => _loading = true);
    final list = await ContentService.instance.search(widget.repo, query);
    if (mounted) {
      setState(() {
        _results = list;
        _loading = false;
      });
    }
  }

  void _onHistoryTap(String query) {
    _controller.text = query;
    _search(query);
  }

  Future<void> _clearHistory() async {
    setState(() => _history.clear());
    await _persistHistory();
  }

  Future<void> _removeHistoryItem(String query) async {
    setState(() => _history.remove(query));
    await _persistHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildHistory() {
    if (_history.isEmpty) {
      return const Expanded(
        child: Center(
          child: Text(
            'Busca algo para empezar',
            style: TextStyle(color: Colors.white38, fontSize: 15),
          ),
        ),
      );
    }

    return Expanded(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Búsquedas recientes',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                TextButton(
                  onPressed: _clearHistory,
                  child: const Text(
                    'Borrar todo',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          ..._history.map(
            (q) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history, color: Colors.white54),
              title: Text(q, style: const TextStyle(color: Colors.white)),
              trailing: IconButton(
                icon: const Icon(Icons.close, color: Colors.white38, size: 18),
                onPressed: () => _removeHistoryItem(q),
              ),
              onTap: () => _onHistoryTap(q),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_results.isEmpty) {
      return const Expanded(
        child: Center(
          child: Text('Sin resultados', style: TextStyle(color: Colors.white54)),
        ),
      );
    }

    final useBackdrop = _useBackdrop;
    final showTitle = _showTitle;

    return Expanded(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
        gridDelegate: useBackdrop
            ? SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 10,
                childAspectRatio: showTitle ? 1.55 : 1.78,
              )
            : SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 8,
                childAspectRatio: showTitle ? 0.58 : 0.68,
              ),
        itemCount: _results.length,
        itemBuilder: (_, i) {
          final item = _results[i];
          final img = useBackdrop
              ? (item.backdrop ?? item.poster)
              : (item.poster ?? item.backdrop);

          return Focusable(
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    DetailsPage(repo: widget.repo, itemId: item.id),
              ));
            },
            builder: (f) => AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: f ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: img != null
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                CachedNetworkImage(
                                  imageUrl: img,
                                  fit: BoxFit.cover,
                                  memCacheWidth: useBackdrop ? 480 : 240,
                                ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: 0,
                                  height: 42,
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.white.withValues(alpha: 0.22),
                                            Colors.transparent,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Container(color: const Color(0xFF1A222D)),
                    ),
                  ),
                  if (showTitle)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
                      child: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
          child: TextField(
            controller: _controller,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Buscar en ${widget.repo.manifest.name}...',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF1A222D),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              prefixIcon: const Icon(Icons.search, color: Colors.white54),
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _results = []);
                      },
                    )
                  : null,
            ),
            onSubmitted: _search,
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (_loading)
          const Expanded(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_showingHistory)
          _buildHistory()
        else
          _buildResults(),
      ],
    );
  }
}
