
import 'package:flutter/material.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/party_service.dart';
import 'party_tv_player.dart';

/// Entrada party TV → player dedicado con foco, dual HLS/media_kit y sidebar.
class TvPartyPlayerPage extends StatelessWidget {
  final PartyRoom room;
  final InstalledRepo repo;

  const TvPartyPlayerPage({
    super.key,
    required this.room,
    required this.repo,
  });

  @override
  Widget build(BuildContext context) {
    return PartyTvPlayer(room: room, repo: repo);
  }
}
