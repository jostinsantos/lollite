import 'package:flutter/material.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/party_service.dart';
import '../../../shared/party_sync_player.dart';

/// Entrada party móvil → player dedicado de sala (sync tiempo real).
class MobilePartyPlayerPage extends StatelessWidget {
  final PartyRoom room;
  final InstalledRepo repo;

  const MobilePartyPlayerPage({
    super.key,
    required this.room,
    required this.repo,
  });

  @override
  Widget build(BuildContext context) {
    return PartySyncPlayer(
      room: room,
      repo: repo,
      isTv: false,
    );
  }
}
