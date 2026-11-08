import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../widgets/focusable.dart';
import '../../widgets/cached_poster.dart';
import '../contenido/contenido.dart';
import '../player/player.dart';
import '../player/playertvoline_mobil.dart';
import 'catalogo_page.dart';
import 'catalogo_individual.dart';

/// Home del repo: carga progresiva real a la API (fila a fila) + fallback legado.
class RepoHomePage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoHomePage({super.key, required this.repo});

  @override
  State<RepoHomePage> createState() => _RepoHomePageState();
}

class _RepoHomePageState extends State<RepoHomePage> {
  /// Esqueleto de filas (puede venir sin items si el addon es progresivo).
  List<HomeRow> _structureRows = [];
  /// Filas ya cargadas desde la API (o del home legado).
  List<HomeRow> _visibleRows = [];
  bool _loading = true;
  bool _legacyFullHome = true;
  int _loadIndex = 0;
  bool _loadingRow = false;
  Timer? _revealTimer;
  final Map<String, PageController> _heroControllers = {};
  final Map<String, int> _heroIndex = {};
  Timer? _heroTimer;
  bool _adsShown = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!refresh) {
      setState(() {
        _loading = true;
        _visibleRows = [];
        _structureRows = [];
        _loadIndex = 0;
        _loadingRow = false;
      });
    }
    _revealTimer?.cancel();

    // 1) Estructura (o home completo si el repo es legado)
    final progressive = await ContentService.instance.getHomeProgressive(
      widget.repo,
      forceRefresh: refresh,
    );
    if (!mounted) return;

    final normalized = <HomeRow>[];
    for (var i = 0; i < progressive.rows.length; i++) {
      var r = progressive.rows[i];
      if (i == 0 && r.type == HomeRowType.row) {
        r = HomeRow(
          id: r.id,
          title: r.title,
          type: HomeRowType.hero,
          items: r.items,
          imageStyle: 'backdrop',
          bannerImage: r.bannerImage,
          bannerUrl: r.bannerUrl,
          catalogId: r.catalogId,
        );
      }
      final items = r.items
          .map((e) => ContentItem(
                id: e.id,
                title: formatTitle(e.title),
                poster: e.poster,
                backdrop: e.backdrop,
                logo: e.logo,
                overview: e.overview,
                type: e.type,
                rating: e.rating,
                year: e.year,
                genres: e.genres,
                seasons: e.seasons,
                season: e.season,
                episode: e.episode,
                extra: e.extra,
              ))
          .toList();
      normalized.add(HomeRow(
        id: r.id,
        title: r.title,
        type: r.type,
        items: items,
        bannerImage: r.bannerImage,
        bannerUrl: r.bannerUrl,
        catalogId: r.catalogId,
        imageStyle: r.imageStyle,
      ));
      if (r.type == HomeRowType.hero) {
        _heroControllers.putIfAbsent(r.id, () => PageController());
        _heroIndex[r.id] = 0;
      }
    }

    setState(() {
      _structureRows = normalized;
      _legacyFullHome = progressive.legacy;
      _loading = false;
      _visibleRows = [];
      _loadIndex = 0;
    });
    _maybeShowAds();
    // 2) Cargar fila a fila (API real o revelar del legado)
    _loadNextRow();
    _startHeroAutoplay();
  }

  /// Carga la siguiente fila: petición a la API si no es legado;
  /// si es legado solo revela la fila ya traída (sin saturar UI).
  Future<void> _loadNextRow() async {
    if (!mounted || _loadingRow) return;
    if (_loadIndex >= _structureRows.length) return;

    _loadingRow = true;
    final skeleton = _structureRows[_loadIndex];

    HomeRow loaded = skeleton;
    if (!_legacyFullHome || skeleton.items.isEmpty) {
      // Petición real a la API por esta fila
      try {
        final page = await ContentService.instance.loadHomeRow(
          widget.repo,
          rowId: skeleton.id,
          catalogId: skeleton.catalogId,
          page: 1,
          fallbackItems: skeleton.items,
        );
        final items = page.items
            .map((e) => ContentItem(
                  id: e.id,
                  title: formatTitle(e.title),
                  poster: e.poster,
                  backdrop: e.backdrop,
                  logo: e.logo,
                  overview: e.overview,
                  type: e.type,
                  rating: e.rating,
                  year: e.year,
                  genres: e.genres,
                  seasons: e.seasons,
                  season: e.season,
                  episode: e.episode,
                  extra: e.extra,
                ))
            .toList();
        // Si la API no devolvió nada, conservar items del esqueleto (legado parcial)
        loaded = HomeRow(
          id: skeleton.id,
          title: skeleton.title,
          type: skeleton.type,
          items: items.isNotEmpty ? items : skeleton.items,
          bannerImage: skeleton.bannerImage,
          bannerUrl: skeleton.bannerUrl,
          catalogId: skeleton.catalogId,
          imageStyle: skeleton.imageStyle,
        );
      } catch (e) {
        debugPrint('[Home] load row ${skeleton.id}: $e');
        loaded = skeleton;
      }
    }

    if (!mounted) return;
    setState(() {
      _visibleRows = [..._visibleRows, loaded];
      _loadIndex++;
      _loadingRow = false;
    });

    if (loaded.type == HomeRowType.hero) {
      _heroControllers.putIfAbsent(loaded.id, () => PageController());
      _heroIndex[loaded.id] = 0;
    }

    // Siguiente fila (poca pausa entre peticiones para no saturar)
    if (_loadIndex < _structureRows.length) {
      _revealTimer?.cancel();
      _revealTimer = Timer(const Duration(milliseconds: 220), () {
        unawaited(_loadNextRow());
      });
    }
  }

  void _startHeroAutoplay() {
    _heroTimer?.cancel();
    _heroTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted) return;
      for (final r in _visibleRows.where((e) => e.type == HomeRowType.hero)) {
        final c = _heroControllers[r.id];
        if (c == null || !c.hasClients || r.items.length < 2) continue;
        final next = ((_heroIndex[r.id] ?? 0) + 1) % r.items.length;
        _heroIndex[r.id] = next;
        c.animateToPage(next, duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
      }
    });
  }


  Future<void> _maybeShowAds() async {
    if (_adsShown || !mounted) return;
    _adsShown = true;
    try {
      final prefs = context.read<RepoPrefs>();
      final repoId = widget.repo.manifest.id;
      // Solo la primera vez que se entra al repo
      if (prefs.adsShown(repoId)) {
        // Aun así refrescar y guardar el aviso para Configuración
        final ads = await ContentService.instance.getAds(widget.repo);
        if (ads.isNotEmpty) {
          final a = ads.first;
          await prefs.saveLastAd(
            repoId,
            title: (a['title'] ?? a['name'] ?? 'Aviso').toString(),
            message: (a['message'] ?? a['body'] ?? a['text'] ?? a['description'] ?? '').toString(),
            image: (a['image'] ?? a['imageUrl'] ?? a['poster'] ?? a['banner'] ?? '').toString(),
            url: (a['url'] ?? a['link'] ?? a['href'] ?? '').toString(),
          );
        }
        return;
      }
      final ads = await ContentService.instance.getAds(widget.repo);
      if (!mounted || ads.isEmpty) return;
      final a = ads.first;
      final title = (a['title'] ?? a['name'] ?? 'Aviso').toString();
      final message = (a['message'] ?? a['body'] ?? a['text'] ?? a['description'] ?? '').toString();
      final image = (a['image'] ?? a['imageUrl'] ?? a['poster'] ?? a['banner'] ?? '').toString();
      final url = (a['url'] ?? a['link'] ?? a['href'] ?? '').toString();
      await prefs.saveLastAd(repoId, title: title, message: message, image: image, url: url);
      await prefs.setAdsShown(repoId);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          final accent = widget.repo.manifest.accentColor;
          return Dialog(
            backgroundColor: const Color(0xFF1A1F2A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Stack(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (image.isNotEmpty)
                        ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Image.network(image, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const SizedBox(height: 120)),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 48, 8),
                        child: Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                      ),
                      if (message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(message,
                              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.35)),
                        ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Row(
                          children: [
                            const Spacer(),
                            if (url.isNotEmpty)
                              FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: accent),
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Ver'),
                              )
                            else
                              FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: accent),
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Entendido'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Cerrar',
                        icon: const Icon(Icons.close, color: Colors.white, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _heroTimer?.cancel();
    for (final c in _heroControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _openItem(ContentItem item) {
    if (item.type == 'catalog') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CatalogDetailPage(repo: widget.repo, catalogId: item.id, title: item.title),
      ));
      return;
    }
    // Canales en vivo: player media_kit dedicado (sin barra de progreso).
    if (item.isChannel) {
      final prefs = context.read<RepoPrefs>();
      final prefLang = widget.repo.userConfig['preferred_language'] ??
          prefs.preferredLanguage(widget.repo.manifest.id);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerMobileOnlinePage(
          title: item.currentProgram != null
              ? '${item.title} · ${item.currentProgram}'
              : item.title,
          url: '',
          repoId: widget.repo.manifest.id,
          contentId: item.id,
          poster: item.poster,
          backdrop: item.backdrop,
          logo: item.logo,
          contentType: item.type,
          servers: const [],
          preferredLanguage: prefLang,
          loadRepo: widget.repo,
        ),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final posterW = context.watch<RepoPrefs>().posterWidth(widget.repo.manifest.id);
    final wide = MediaQuery.sizeOf(context).width > 700;

    return RefreshIndicator(
      color: const Color(0xFFE50914),
      backgroundColor: const Color(0xFF1A222D),
      onRefresh: () => _load(refresh: true),
      child: _loading
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 16),
                SkeletonRow(height: 200, itemWidth: 280, count: 3),
                SizedBox(height: 20),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(height: 14, width: 120, child: ColoredBox(color: Color(0xFF1A222D))),
                ),
                SizedBox(height: 8),
                SkeletonRow(height: 160, itemWidth: 110, count: 6),
                SizedBox(height: 20),
                SkeletonRow(height: 160, itemWidth: 110, count: 6),
              ],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              // Espacio extra abajo para que el último slider/fila (poster + título)
              // no quede tapado por el menú inferior flotante.
              padding: const EdgeInsets.only(bottom: 140),
              children: [
                for (final row in _visibleRows) ...[
                  if (row.type == HomeRowType.hero) _buildHero(row, wide),
                  if (row.type == HomeRowType.banner) _buildBanner(row, wide),
                  if (row.type == HomeRowType.row) _buildSecondary(row, posterW, wide),
                  if (row.type == HomeRowType.catalog) _buildCatalogRow(row, posterW, wide),
                ],
                // skeletons de filas aún no reveladas
                if (_loadIndex < _structureRows.length || _loadingRow)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: SkeletonRow(height: 150, itemWidth: 110, count: 5),
                  ),
              ],
            ),
    );
  }

  Widget _buildHero(HomeRow row, bool wide) {
    final items = row.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final ctrl = _heroControllers[row.id] ?? PageController();
    // Hero más alto estilo Nuvio (~0.55–0.62 del alto de pantalla en móvil).
    final screenH = MediaQuery.sizeOf(context).height;
    final h = wide
        ? (screenH * 0.42).clamp(280.0, 420.0)
        : (screenH * 0.58).clamp(320.0, 520.0);
    final current = _heroIndex[row.id] ?? 0;

    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: ctrl,
            itemCount: items.length,
            onPageChanged: (i) => setState(() => _heroIndex[row.id] = i),
            itemBuilder: (context, i) {
              final item = items[i];
              final image = item.backdrop ?? item.poster;
              return Focusable(
                onTap: () => _openItem(item),
                builder: (focused) => Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedPoster.backdrop(image, height: h),
                    // Gradientes estilo Nuvio (arriba + abajo).
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x66000000),
                            Colors.transparent,
                            Colors.transparent,
                            Color(0xEE0B0E14),
                          ],
                          stops: [0.0, 0.25, 0.55, 1.0],
                        ),
                      ),
                    ),
                    // Contenido inferior: logo / título + meta + CTA.
                    Positioned(
                      left: wide ? 32 : 20,
                      right: wide ? 32 : 20,
                      bottom: wide ? 28 : 22,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.logo != null && item.logo!.isNotEmpty)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: wide ? 280 : 200,
                                maxHeight: wide ? 72 : 56,
                              ),
                              child: CachedPoster(
                                url: item.logo,
                                fit: BoxFit.contain,
                                title: item.title,
                                sheenStrength: 0,
                              ),
                            )
                          else
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: wide ? 28 : 22,
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                                shadows: const [
                                  Shadow(blurRadius: 12, color: Colors.black87),
                                ],
                              ),
                            ),
                          const SizedBox(height: 8),
                          // Meta: año · rating · géneros
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (item.year != null && item.year!.isNotEmpty)
                                Text(
                                  item.year!,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              if (item.rating != null) ...[
                                const Text('·', style: TextStyle(color: Colors.white38)),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.star_rounded,
                                        size: 15, color: Color(0xFFFFC107)),
                                    const SizedBox(width: 3),
                                    Text(
                                      item.rating!.toStringAsFixed(1),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (item.genres.isNotEmpty) ...[
                                const Text('·', style: TextStyle(color: Colors.white38)),
                                Text(
                                  item.genres.take(2).join(', '),
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFE50914),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 18, vertical: 10),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                onPressed: () => _openItem(item),
                                icon: const Icon(Icons.play_arrow_rounded, size: 22),
                                label: const Text(
                                  'Ver ahora',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              if (focused) ...[
                                const SizedBox(width: 10),
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFFF2D2D),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // Indicadores de página
          if (items.length > 1)
            Positioned(
              right: 16,
              bottom: 18,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(items.length.clamp(0, 8), (i) {
                  final active = i == current;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(left: 4),
                    width: active ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: active ? Colors.white : Colors.white38,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBanner(HomeRow row, bool wide) {
    final img = row.bannerImage ??
        (row.items.isNotEmpty ? (row.items.first.backdrop ?? row.items.first.poster) : null);
    if (img == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 12, 10, wide ? 20 : 12, 10),
      child: Focusable(
        onTap: () {
          if (row.items.isNotEmpty) _openItem(row.items.first);
        },
        builder: (focused) => AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: wide ? 100.0 : 80.0,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: focused ? const Color(0xFFFF2D2D) : Colors.transparent, width: 2.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedPoster.backdrop(img, height: wide ? 100 : 80),
          ),
        ),
      ),
    );
  }

  Widget _buildSecondary(HomeRow row, double posterW, bool wide) {
    final useBackdrop = row.imageStyle == 'backdrop';
    final h = useBackdrop ? (wide ? 140.0 : 110.0) : posterW * 1.5;
    final w = useBackdrop ? (wide ? 220.0 : 160.0) : posterW;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
          child: Text(
            row.title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 17,
              letterSpacing: -0.2,
            ),
          ),
        ),
        SizedBox(
          height: h + (useBackdrop ? 0 : 28),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: row.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, j) {
              final item = row.items[j];
              final img = useBackdrop ? (item.backdrop ?? item.poster) : (item.poster ?? item.backdrop);
              return Focusable(
                onTap: () => _openItem(item),
                builder: (focused) => AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: w,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: focused ? const Color(0xFFFF2D2D) : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: useBackdrop
                              ? CachedPoster.backdrop(img, height: h)
                              : CachedPoster.poster(img, width: w, height: h),
                        ),
                      ),
                      if (!useBackdrop) ...[
                        const SizedBox(height: 6),
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCatalogRow(HomeRow row, double posterW, bool wide) {
    final h = wide ? 90.0 : 72.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Expanded(
                  child: Text(row.title.isEmpty ? 'Catálogos' : row.title,
                      style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600))),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CatalogsPage(repo: widget.repo),
                  ));
                },
                child: const Text('Ver todos', style: TextStyle(color: Color(0xFFE50914))),
              ),
            ],
          ),
        ),
        SizedBox(
          height: h,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: row.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, j) {
              final item = row.items[j];
              return Focusable(
                onTap: () => _openItem(ContentItem(
                  id: item.id,
                  title: item.title,
                  poster: item.poster,
                  backdrop: item.backdrop,
                  type: 'catalog',
                )),
                builder: (focused) => AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: wide ? 260.0 : 200.0,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: focused ? const Color(0xFFFF2D2D) : Colors.transparent, width: 2.5),
                    color: const Color(0xFF1A222D),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (item.backdrop != null || item.poster != null)
                          CachedPoster.backdrop(item.backdrop ?? item.poster, height: h),
                        Container(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          color: Colors.black38,
                          child: Text(item.title,
                              maxLines: 2,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}