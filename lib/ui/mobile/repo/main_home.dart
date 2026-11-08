import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/models/repo_manifest.dart';
import 'home/home.dart';
import 'descubrir/descubrir.dart';
import 'buscar/buscar.dart';
import 'biblioteca/biblioteca.dart';
import 'config/config.dart';
import 'live/live.dart';

/// Shell del repo en móvil (barra inferior según tabs del lol.json / capabilities).
class RepoMainHome extends StatefulWidget {
  final InstalledRepo repo;
  const RepoMainHome({super.key, required this.repo});

  @override
  State<RepoMainHome> createState() => _RepoMainHomeState();
}

class _RepoMainHomeState extends State<RepoMainHome> {
  int _index = 0;

  List<({String id, Widget page, IconData icon, IconData selectedIcon, String label})>
      _buildTabs(InstalledRepo repo) {
    final order = repo.manifest.resolvedTabs;
    final out =
        <({String id, Widget page, IconData icon, IconData selectedIcon, String label})>[];
    for (final id in order) {
      switch (id) {
        case 'home':
          out.add((
            id: id,
            page: RepoHomePage(repo: repo),
            icon: Icons.home_outlined,
            selectedIcon: Icons.home,
            label: 'Inicio',
          ));
        case 'discover':
          out.add((
            id: id,
            page: RepoDiscoverPage(repo: repo),
            icon: Icons.explore_outlined,
            selectedIcon: Icons.explore,
            label: 'Descubrir',
          ));
        case 'search':
          out.add((
            id: id,
            page: RepoSearchPage(repo: repo),
            icon: Icons.search,
            selectedIcon: Icons.search,
            label: 'Buscar',
          ));
        case 'live':
          out.add((
            id: id,
            page: RepoLivePage(repo: repo),
            icon: Icons.live_tv_outlined,
            selectedIcon: Icons.live_tv,
            label: 'TV Online',
          ));
        case 'library':
          out.add((
            id: id,
            page: RepoLibraryPage(repo: repo),
            icon: Icons.bookmark_border,
            selectedIcon: Icons.bookmark,
            label: 'Biblioteca',
          ));
        case 'settings':
          out.add((
            id: id,
            page: RepoSettingsPage(repo: repo),
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: 'Ajustes',
          ));
      }
    }
    if (out.isEmpty) {
      out.add((
        id: 'home',
        page: RepoHomePage(repo: repo),
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'Inicio',
      ));
    }
    return out;
  }

  /// Color oscuro para el menú inferior flotante.
  Color _darkBarColor(Color surface) {
    // Preferir un negro/semitransparente o surface oscuro.
    final base = surface.computeLuminance() < 0.25 ? surface : const Color(0xFF12161C);
    return Color.lerp(base, Colors.black, 0.55) ?? const Color(0xFF0D1117);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.repo.manifest;
    final theme = m.theme.hasAny || m.color != null
        ? m.theme.toThemeData()
        : Theme.of(context);
    final bg = m.backgroundColor;
    final surface = m.surfaceColor;
    final darkBar = _darkBarColor(surface);
    // Rojo fijo para el ítem seleccionado (como pidió el usuario)
    const selectedRed = Color(0xFFE50914);

    final tabs = _buildTabs(widget.repo);
    if (_index >= tabs.length) _index = 0;

    final isHome = tabs[_index].id == 'home';
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: bg,
        // Sin AppBar ni bottomNavigationBar fijo: todo flotante en el Stack
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Contenido: en home a pantalla completa (hero inmersivo);
            // en otras pestañas se deja espacio superior para la barra "original".
            Positioned.fill(
              child: isHome
                  ? tabs[_index].page
                  : Padding(
                      padding: EdgeInsets.only(top: topPad + 52),
                      child: tabs[_index].page,
                    ),
            ),

            // Controles superiores:
            // - Solo en Home: estilo flotante con blur (como se pidió)
            // - En las demás: versión más "original" (barra sólida oscura)
            if (isHome)
              Positioned(
                top: topPad + 8,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    ClipOval(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.35),
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => Navigator.of(context).maybePop(),
                            child: const SizedBox(
                              width: 42,
                              height: 42,
                              child: Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (m.icon != null && m.icon!.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.15),
                                width: 1,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(11),
                              child: CachedNetworkImage(
                                imageUrl: m.icon!,
                                width: 42,
                                height: 42,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(
                                  color: surface,
                                  alignment: Alignment.center,
                                  child: Text(
                                    m.name.isNotEmpty
                                        ? m.name[0].toUpperCase()
                                        : 'R',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          m.name.isNotEmpty ? m.name[0].toUpperCase() : 'R',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              )
            else
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: EdgeInsets.only(
                    top: topPad + 6,
                    left: 8,
                    right: 12,
                    bottom: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.82),
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(
                          Icons.arrow_back_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          tabs[_index].label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (m.icon != null && m.icon!.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedNetworkImage(
                            imageUrl: m.icon!,
                            width: 32,
                            height: 32,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => const SizedBox.shrink(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

            // Menú inferior FLOTANTE: más oscuro, iconos blancos, seleccionado rojo
            Positioned(
              left: 16,
              right: 16,
              bottom: bottomPad + 12,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      color: darkBar.withValues(alpha: 0.78),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        for (var i = 0; i < tabs.length; i++)
                          Expanded(
                            child: _NavItem(
                              icon: tabs[i].icon,
                              selectedIcon: tabs[i].selectedIcon,
                              label: tabs[i].label,
                              selected: i == _index,
                              selectedColor: selectedRed,
                              onTap: () => setState(() => _index = i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Iconos blancos; el seleccionado en rojo
    final color = selected ? selectedColor : Colors.white.withValues(alpha: 0.88);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: selected
                ? selectedColor.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? selectedIcon : icon,
                color: color,
                size: 22,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight:
                      selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}