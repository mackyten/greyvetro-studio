import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../core/audio_player.dart';
import '../../core/theme.dart';
import 'create_voice_screen.dart';
import 'favorites_repository.dart';
import 'voice_model.dart';

class VoicesScreen extends StatefulWidget {
  final ApiClient apiClient;
  final AudioPlayer player;
  final ValueChanged<VoiceModel> onVoiceSelected;
  final VoiceModel? selectedVoice;

  const VoicesScreen({
    super.key,
    required this.apiClient,
    required this.player,
    required this.onVoiceSelected,
    this.selectedVoice,
  });

  @override
  State<VoicesScreen> createState() => _VoicesScreenState();
}

class _VoicesScreenState extends State<VoicesScreen> {
  late Future<List<VoiceModel>> _voices;
  final _searchController = TextEditingController();
  final _favoritesRepo = FavoritesRepository();
  final _previewPlayer = ap.AudioPlayer();
  String _query = '';
  String? _genderFilter;
  Set<String> _favorites = {};
  bool _favoritesOnly = false;
  String? _previewingId;

  @override
  void initState() {
    super.initState();
    _voices = widget.apiClient.getVoices();
    _searchController.addListener(
      () => setState(() => _query = _searchController.text.trim().toLowerCase()),
    );
    _favoritesRepo.load().then((ids) {
      if (mounted) setState(() => _favorites = ids);
    });
    _previewPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _previewingId = null);
    });
  }

  /// Toggles preview playback of [v.previewUrl]; starting a new preview
  /// stops whichever one is currently playing (one shared player instance,
  /// independent of the app-wide gallery/composer [AudioPlayer]).
  Future<void> _togglePreview(VoiceModel v) async {
    final url = v.previewUrl;
    if (url == null) return;
    if (_previewingId == v.id) {
      await _previewPlayer.stop();
      setState(() => _previewingId = null);
      return;
    }
    await _previewPlayer.stop();
    setState(() => _previewingId = v.id);
    await _previewPlayer.play(ap.UrlSource(url));
  }

  Future<void> _toggleFavorite(String voiceId) async {
    final ids = await _favoritesRepo.toggle(voiceId);
    if (mounted) setState(() => _favorites = ids);
  }

  /// Favorited voices float to the top, original order preserved within each group.
  List<VoiceModel> _sortFavoritesFirst(List<VoiceModel> list) {
    final favs = list.where((v) => _favorites.contains(v.id)).toList();
    final rest = list.where((v) => !_favorites.contains(v.id)).toList();
    return [...favs, ...rest];
  }

  @override
  void dispose() {
    _searchController.dispose();
    _previewPlayer.dispose();
    super.dispose();
  }

  /// Re-fetch the voice list from the backend (e.g. after upgrading a plan
  /// or cloning a new voice). Awaits the new future so callers like
  /// [RefreshIndicator] can keep the spinner up until it resolves.
  Future<void> _reload() async {
    final future = widget.apiClient.getVoices();
    setState(() => _voices = future);
    await future;
  }

  bool _matches(VoiceModel v) {
    if (_genderFilter != null &&
        (v.gender?.toLowerCase() != _genderFilter!.toLowerCase())) {
      return false;
    }
    if (_favoritesOnly && !_favorites.contains(v.id)) return false;
    if (_query.isEmpty) return true;
    return v.name.toLowerCase().contains(_query) ||
        v.description.toLowerCase().contains(_query) ||
        v.labels.values.any((l) => l.toLowerCase().contains(_query));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.brand;
    return FutureBuilder<List<VoiceModel>>(
      future: _voices,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Could not load voices.\n${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.text2),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        final all = snapshot.data!;
        final genders = all
            .map((v) => v.gender)
            .where((g) => g != null && g.trim().isNotEmpty)
            .map((g) => g!.trim().toLowerCase())
            .toSet()
            .toList()
          ..sort();

        final filtered = all.where(_matches).toList();
        final custom = _sortFavoritesFirst(filtered.where((v) => v.isCustom).toList());
        final builtIn = _sortFavoritesFirst(filtered.where((v) => !v.isCustom).toList());

        return Column(
          children: [
            _searchBar(),
            _filterChips(genders),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _reload,
                color: c.blueDeep,
                child: filtered.isEmpty
                    ? ListView(
                        // AlwaysScrollable so pull-to-refresh still works
                        // even when no voices match the current search.
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Center(
                            child: Text(
                              'No voices match your search.',
                              style: TextStyle(color: c.text3),
                            ),
                          ),
                        ],
                      )
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                        children: [
                          _createVoiceButton(),
                          if (custom.isNotEmpty) ...[
                            _sectionHeader('My Voices'),
                            ...custom.map(_tile),
                            const SizedBox(height: 8),
                          ],
                          if (builtIn.isNotEmpty) ...[
                            _sectionHeader('Free Voices'),
                            ...builtIn.map(_tile),
                          ],
                        ],
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _searchBar() {
    final c = context.brand;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search voices…',
                prefixIcon: Icon(Icons.search_rounded, color: c.text3),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () => _searchController.clear(),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: c.text2),
            tooltip: 'Refresh voices',
            onPressed: _reload,
          ),
        ],
      ),
    );
  }

  Widget _filterChips(List<String> genders) => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            _chip('All', _genderFilter == null,
                () => setState(() => _genderFilter = null)),
            ...genders.map((g) => _chip(
                  _capitalize(g),
                  _genderFilter == g,
                  () => setState(
                      () => _genderFilter = _genderFilter == g ? null : g),
                )),
            _chip(
              'Favorites',
              _favoritesOnly,
              () => setState(() => _favoritesOnly = !_favoritesOnly),
              icon: _favoritesOnly ? Icons.star_rounded : Icons.star_border_rounded,
              activeColor: context.brand.warning,
            ),
          ],
        ),
      );

  Widget _chip(
    String label,
    bool selected,
    VoidCallback onTap, {
    IconData? icon,
    Color? activeColor,
  }) {
    final c = context.brand;
    final selectedColor = activeColor ?? c.blueDeep;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: icon != null
            ? Icon(icon, size: 16, color: selected ? selectedColor : c.text3)
            : null,
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        backgroundColor: c.surface,
        selectedColor: selectedColor.withValues(alpha: 0.28),
        side: BorderSide(color: selected ? selectedColor : c.outline),
        labelStyle: TextStyle(
          color: c.text,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  Future<void> _openCreateVoice() async {
    final voice = await Navigator.of(context).push<VoiceModel>(
      MaterialPageRoute(
        builder: (_) => CreateVoiceScreen(
          apiClient: widget.apiClient,
          player: widget.player,
        ),
      ),
    );
    if (voice == null) return;
    // Refresh the list so the new voice shows under "My Voices", then select it.
    _reload();
    widget.onVoiceSelected(voice);
  }

  Widget _createVoiceButton() {
    final c = context.brand;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Material(
        color: c.pink.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(AppRadii.field),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.field),
          onTap: _openCreateVoice,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.field),
              border: Border.all(color: c.pinkDeep.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.surface,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.add_rounded, color: c.pinkDeep),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Create my voice',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: c.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Record or upload samples to clone a voice',
                        style: TextStyle(fontSize: 13, color: c.text3),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: c.text3),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _favoriteButton(VoiceModel v) {
    final c = context.brand;
    final isFavorite = _favorites.contains(v.id);
    return IconButton(
      icon: Icon(
        isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
        color: isFavorite ? c.warning : c.text3,
      ),
      tooltip: isFavorite ? 'Remove from favorites' : 'Add to favorites',
      onPressed: () => _toggleFavorite(v.id),
      splashRadius: 20,
    );
  }

  Widget _previewButton(VoiceModel v) {
    if (v.previewUrl == null) return const SizedBox.shrink();
    final c = context.brand;
    final isPlaying = _previewingId == v.id;
    return IconButton(
      icon: Icon(
        isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
        color: isPlaying ? c.blueDeep : c.text3,
      ),
      tooltip: isPlaying ? 'Stop preview' : 'Play preview',
      onPressed: () => _togglePreview(v),
      splashRadius: 20,
    );
  }

  Widget _sectionHeader(String title) {
    final c = context.brand;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        title.toUpperCase(),
        style: AppFonts.monoStyle(
          size: 11,
          weight: FontWeight.w500,
          color: c.text3,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _tile(VoiceModel v) {
    final c = context.brand;
    final selected = widget.selectedVoice?.id == v.id;
    final subtitle = v.tagline;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? c.blue.withValues(alpha: 0.16) : c.surface,
        borderRadius: BorderRadius.circular(AppRadii.field),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.field),
          onTap: () => widget.onVoiceSelected(v),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.field),
              border: Border.all(
                color: selected ? c.blueDeep : c.outline,
                width: selected ? 1.5 : 1,
              ),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: v.isCustom
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [c.pinkDeep, c.pink],
                          )
                        : c.sliderGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    v.name.isNotEmpty ? v.name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: c.text,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: c.text3),
                        ),
                      ],
                    ],
                  ),
                ),
                _favoriteButton(v),
                _previewButton(v),
                if (selected) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.check_circle_rounded, color: c.blueDeep),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
