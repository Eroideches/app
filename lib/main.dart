import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =========================================================================
// ENTRY POINT
// =========================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // L'inizializzazione del servizio di background è avvolta in un try/catch:
  // se fallisce (permesso notifiche negato su Android 13+, piattaforma web,
  // o altro problema nativo) l'app deve comunque avviarsi e mostrare la UI
  // invece di restare bloccata su schermo nero prima ancora di runApp().
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.soundstream.app.channel.audio',
      androidNotificationChannelName: 'Riproduzione audio',
      androidNotificationOngoing: true,
    );
  } catch (e) {
    debugPrint('JustAudioBackground non inizializzato: $e');
  }
  runApp(const SoundStreamApp());
}

class SoundStreamApp extends StatelessWidget {
  const SoundStreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerManager()..init(),
      child: MaterialApp(
        title: 'SoundStream',
        debugShowCheckedModeBanner: false,
        theme: _buildDarkTheme(),
        darkTheme: _buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: const RootScreen(),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1DB954),
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF121212),
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xFF181818),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
    );
  }
}

// =========================================================================
// MODELLO DATI
// =========================================================================

class Song {
  final String id;
  final String title;
  final String artist;
  final String thumbnailUrl;
  final int durationSeconds;
  String? streamUrl;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    required this.durationSeconds,
    this.streamUrl,
  });

  factory Song.fromPipedJson(Map<String, dynamic> json) {
    final url = json['url'] as String? ?? '';
    final id = url.contains('v=') ? url.split('v=').last : '';
    return Song(
      id: id,
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : 'Titolo sconosciuto',
      artist: (json['uploaderName'] as String?) ??
          (json['uploader'] as String?) ??
          'Artista sconosciuto',
      thumbnailUrl: (json['thumbnail'] as String?) ?? '',
      durationSeconds: (json['duration'] as num?)?.toInt() ?? 0,
    );
  }
}

String formatDuration(Duration d) {
  if (d.isNegative || d == Duration.zero) return '0:00';
  final minutes = d.inMinutes.remainder(60).toString();
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = d.inHours;
  if (hours > 0) {
    return '$hours:${minutes.padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

// =========================================================================
// SERVIZIO PIPED API (ricerca + estrazione stream audio da YouTube)
// =========================================================================

class PipedApiException implements Exception {
  final String message;
  PipedApiException(this.message);
  @override
  String toString() => message;
}

class PipedService {
  // Elenco di istanze pubbliche Piped, usate in ordine come fallback:
  // se un'istanza non risponde si prova automaticamente la successiva.
  static const List<String> _instances = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.adminforge.de',
    'https://api.piped.yt',
    'https://piped-api.lunar.icu',
    'https://pipedapi.leptons.xyz',
  ];

  static Future<List<Song>> search(String query) async {
    if (query.trim().isEmpty) return [];
    Object? lastError;

    for (final instance in _instances) {
      try {
        final uri = Uri.parse('$instance/search').replace(queryParameters: {
          'q': query,
          'filter': 'music_songs',
        });
        final response = await http.get(uri).timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final items = (data['items'] as List<dynamic>?) ?? [];
          final songs = items
              .whereType<Map<String, dynamic>>()
              .where((item) =>
                  item['url'] != null &&
                  (item['url'] as String).contains('watch?v='))
              .map(Song.fromPipedJson)
              .where((song) => song.id.isNotEmpty)
              .toList();
          return songs;
        }
      } catch (e) {
        lastError = e;
        continue;
      }
    }
    throw PipedApiException(
      'Nessuna istanza Piped raggiungibile al momento. Riprova più tardi. '
      '(${lastError ?? "errore sconosciuto"})',
    );
  }

  static Future<String> getAudioStreamUrl(String videoId) async {
    Object? lastError;

    for (final instance in _instances) {
      try {
        final uri = Uri.parse('$instance/streams/$videoId');
        final response = await http.get(uri).timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final audioStreams =
              (data['audioStreams'] as List<dynamic>?) ?? [];
          if (audioStreams.isEmpty) continue;

          final streams = audioStreams.whereType<Map<String, dynamic>>().toList();
          streams.sort((a, b) {
            final bitrateA = int.tryParse('${a['bitrate'] ?? 0}') ?? 0;
            final bitrateB = int.tryParse('${b['bitrate'] ?? 0}') ?? 0;
            return bitrateB.compareTo(bitrateA);
          });

          final url = streams.first['url'] as String?;
          if (url != null && url.isNotEmpty) return url;
        }
      } catch (e) {
        lastError = e;
        continue;
      }
    }
    throw PipedApiException(
      'Impossibile ottenere lo stream audio per questo brano. '
      '(${lastError ?? "errore sconosciuto"})',
    );
  }
}

// =========================================================================
// PLAYER MANAGER (stato globale: player, coda, playlist)
// =========================================================================

class PlayerManager extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();

  List<Song> _queue = [];
  int _currentIndex = -1;
  bool _isLoading = false;
  String? _errorMessage;

  final Map<String, List<Song>> _playlists = {};
  static const String _playlistsPrefsKey = 'soundstream_playlists_v1';

  PlayerManager() {
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        playNext();
      }
      notifyListeners();
    });
  }

  // Da chiamare una volta all'avvio dell'app per ripristinare le playlist salvate.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_playlistsPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _playlists.clear();
        decoded.forEach((name, songsJson) {
          final songs = (songsJson as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map((s) => Song(
                    id: s['id'] as String,
                    title: s['title'] as String,
                    artist: s['artist'] as String,
                    thumbnailUrl: s['thumbnailUrl'] as String,
                    durationSeconds: s['durationSeconds'] as int,
                  ))
              .toList();
          _playlists[name] = songs;
        });
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Impossibile caricare le playlist salvate: $e');
    }
  }

  Future<void> _persistPlaylists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _playlists.map((name, songs) => MapEntry(
            name,
            songs
                .map((s) => {
                      'id': s.id,
                      'title': s.title,
                      'artist': s.artist,
                      'thumbnailUrl': s.thumbnailUrl,
                      'durationSeconds': s.durationSeconds,
                    })
                .toList(),
          ));
      await prefs.setString(_playlistsPrefsKey, jsonEncode(data));
    } catch (e) {
      debugPrint('Impossibile salvare le playlist: $e');
    }
  }

  AudioPlayer get player => _player;
  List<Song> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  Song? get currentSong =>
      (_currentIndex >= 0 && _currentIndex < _queue.length)
          ? _queue[_currentIndex]
          : null;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  Map<String, List<Song>> get playlists => Map.unmodifiable(_playlists);

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    _queue = List<Song>.from(songs);
    _currentIndex = startIndex.clamp(0, _queue.length - 1);
    await _playCurrent();
  }

  Future<void> _playCurrent() async {
    final song = currentSong;
    if (song == null) return;

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final streamUrl = song.streamUrl ?? await PipedService.getAudioStreamUrl(song.id);
      song.streamUrl = streamUrl;

      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(streamUrl),
          tag: MediaItem(
            id: song.id,
            title: song.title,
            artist: song.artist,
            artUri: song.thumbnailUrl.isNotEmpty ? Uri.tryParse(song.thumbnailUrl) : null,
          ),
        ),
      );
      await _player.play();
    } catch (e) {
      _errorMessage = 'Impossibile riprodurre "${song.title}": $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> togglePlayPause() async {
    if (currentSong == null) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    notifyListeners();
  }

  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    if (_currentIndex < _queue.length - 1) {
      _currentIndex++;
      await _playCurrent();
    } else {
      await _player.stop();
      notifyListeners();
    }
  }

  Future<void> playPrevious() async {
    if (_queue.isEmpty) return;
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_currentIndex > 0) {
      _currentIndex--;
      await _playCurrent();
    } else {
      await _player.seek(Duration.zero);
    }
  }

  Future<void> playFromQueueAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _currentIndex = index;
    await _playCurrent();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  void addToQueue(Song song) {
    _queue.add(song);
    if (_currentIndex == -1) _currentIndex = 0;
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);

    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex) {
      if (_queue.isEmpty) {
        _currentIndex = -1;
        _player.stop();
      } else {
        if (_currentIndex >= _queue.length) _currentIndex = _queue.length - 1;
        _playCurrent();
      }
    }
    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final song = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, song);

    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    notifyListeners();
  }

  void createPlaylist(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || _playlists.containsKey(trimmed)) return;
    _playlists[trimmed] = [];
    notifyListeners();
    _persistPlaylists();
  }

  void deletePlaylist(String name) {
    _playlists.remove(name);
    notifyListeners();
    _persistPlaylists();
  }

  void addToPlaylist(String name, Song song) {
    final list = _playlists[name];
    if (list == null) return;
    if (list.any((s) => s.id == song.id)) return;
    list.add(song);
    notifyListeners();
    _persistPlaylists();
  }

  void removeFromPlaylist(String name, Song song) {
    final list = _playlists[name];
    if (list == null) return;
    list.removeWhere((s) => s.id == song.id);
    notifyListeners();
    _persistPlaylists();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

// =========================================================================
// ROOT SCREEN (Home + Playlist con mini-player persistente)
// =========================================================================

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _tabIndex,
                children: const [
                  HomeScreen(),
                  PlaylistsScreen(),
                ],
              ),
            ),
            const MiniPlayer(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.queue_music_outlined), selectedIcon: Icon(Icons.queue_music), label: 'Playlist'),
        ],
      ),
    );
  }
}

// =========================================================================
// MINI PLAYER
// =========================================================================

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerManager>(
      builder: (context, manager, _) {
        final song = manager.currentSong;
        if (song == null) return const SizedBox.shrink();

        return InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PlayerScreen()),
          ),
          child: Container(
            height: 64,
            color: const Color(0xFF242424),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SongThumbnail(url: song.thumbnailUrl, size: 44),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                    ],
                  ),
                ),
                if (manager.isLoading)
                  const SizedBox(width: 32, height: 32, child: Padding(padding: EdgeInsets.all(6), child: CircularProgressIndicator(strokeWidth: 2)))
                else
                  IconButton(
                    icon: Icon(manager.player.playing ? Icons.pause : Icons.play_arrow, size: 32),
                    onPressed: manager.togglePlayPause,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =========================================================================
// WIDGET RIUTILIZZABILI
// =========================================================================

class SongThumbnail extends StatelessWidget {
  final String url;
  final double size;
  const SongThumbnail({super.key, required this.url, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: const Color(0xFF303030),
      child: url.isEmpty
          ? Icon(Icons.music_note, color: Colors.grey[500], size: size * 0.5)
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(Icons.music_note, color: Colors.grey[500], size: size * 0.5),
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return Center(child: Icon(Icons.music_note, color: Colors.grey[700], size: size * 0.5));
              },
            ),
    );
  }
}

class SongListTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onRemove;
  final bool isPlaying;

  const SongListTile({
    super.key,
    required this.song,
    required this.onTap,
    this.onAddToQueue,
    this.onAddToPlaylist,
    this.onRemove,
    this.isPlaying = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SongThumbnail(url: song.thumbnailUrl),
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: isPlaying ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
      subtitle: Text(
        '${song.artist} · ${formatDuration(Duration(seconds: song.durationSeconds))}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: onRemove != null
          ? IconButton(icon: const Icon(Icons.close), onPressed: onRemove)
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'queue') onAddToQueue?.call();
                if (value == 'playlist') onAddToPlaylist?.call();
              },
              itemBuilder: (context) => [
                if (onAddToQueue != null)
                  const PopupMenuItem(value: 'queue', child: Text('Aggiungi alla coda')),
                if (onAddToPlaylist != null)
                  const PopupMenuItem(value: 'playlist', child: Text('Aggiungi a playlist')),
              ],
            ),
    );
  }
}

Future<void> showAddToPlaylistSheet(BuildContext context, Song song) {
  final manager = context.read<PlayerManager>();
  return showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    builder: (context) {
      return SafeArea(
        child: Consumer<PlayerManager>(
          builder: (context, manager, _) {
            final names = manager.playlists.keys.toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Aggiungi a playlist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                if (names.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('Nessuna playlist. Creane una dalla scheda Playlist.'),
                  ),
                ...names.map((name) => ListTile(
                      leading: const Icon(Icons.playlist_play),
                      title: Text(name),
                      onTap: () {
                        manager.addToPlaylist(name, song);
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Aggiunto a "$name"')),
                        );
                      },
                    )),
                const SizedBox(height: 12),
              ],
            );
          },
        ),
      );
    },
  );
}

// =========================================================================
// HOME SCREEN (ricerca)
// =========================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _controller = TextEditingController();
  List<Song> _results = [];
  bool _isSearching = false;
  String? _error;

  Future<void> _runSearch() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isSearching = true;
      _error = null;
    });

    try {
      final results = await PipedService.search(query);
      setState(() => _results = results);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _results = [];
      });
    } finally {
      setState(() => _isSearching = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<PlayerManager>();

    return Scaffold(
      appBar: AppBar(title: const Text('SoundStream')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runSearch(),
              decoration: InputDecoration(
                hintText: 'Cerca brani o artisti...',
                filled: true,
                fillColor: const Color(0xFF242424),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _isSearching
                    ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _runSearch),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: TextStyle(color: Colors.red[300])),
            ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _isSearching ? 'Ricerca in corso...' : 'Cerca un brano per iniziare',
                      style: TextStyle(color: Colors.grey[500]),
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final song = _results[index];
                      final isCurrent = manager.currentSong?.id == song.id;
                      return SongListTile(
                        song: song,
                        isPlaying: isCurrent,
                        onTap: () => manager.playQueue(_results, index),
                        onAddToQueue: () {
                          manager.addToQueue(song);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('"${song.title}" aggiunto alla coda')),
                          );
                        },
                        onAddToPlaylist: () => showAddToPlaylistSheet(context, song),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// PLAYER SCREEN
// =========================================================================

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerManager>(
      builder: (context, manager, _) {
        final song = manager.currentSong;

        return Scaffold(
          appBar: AppBar(
            title: const Text('In riproduzione'),
            actions: [
              IconButton(
                icon: const Icon(Icons.queue_music),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const QueueScreen()),
                ),
              ),
            ],
          ),
          body: song == null
              ? const Center(child: Text('Nessun brano in riproduzione'))
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Spacer(),
                      AspectRatio(
                        aspectRatio: 1,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: SongThumbnail(url: song.thumbnailUrl, size: 280),
                        ),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        song.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        song.artist,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15, color: Colors.grey[400]),
                      ),
                      const SizedBox(height: 16),
                      if (manager.errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(manager.errorMessage!, style: TextStyle(color: Colors.red[300]), textAlign: TextAlign.center),
                        ),
                      _PlayerSeekBar(manager: manager),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.skip_previous, size: 40),
                            onPressed: manager.playPrevious,
                          ),
                          const SizedBox(width: 16),
                          if (manager.isLoading)
                            const SizedBox(
                              width: 72,
                              height: 72,
                              child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
                            )
                          else
                            IconButton(
                              icon: Icon(manager.player.playing ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 72),
                              onPressed: manager.togglePlayPause,
                            ),
                          const SizedBox(width: 16),
                          IconButton(
                            icon: const Icon(Icons.skip_next, size: 40),
                            onPressed: manager.playNext,
                          ),
                        ],
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _PlayerSeekBar extends StatelessWidget {
  final PlayerManager manager;
  const _PlayerSeekBar({required this.manager});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: manager.player.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final duration = manager.player.duration ?? Duration.zero;
        final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
        final valueMs = position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                min: 0,
                max: maxMs,
                value: valueMs,
                onChanged: (value) {
                  manager.seek(Duration(milliseconds: value.toInt()));
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDuration(position), style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                  Text(formatDuration(duration), style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// =========================================================================
// QUEUE SCREEN
// =========================================================================

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerManager>(
      builder: (context, manager, _) {
        final queue = manager.queue;
        return Scaffold(
          appBar: AppBar(title: const Text('Coda di riproduzione')),
          body: queue.isEmpty
              ? const Center(child: Text('La coda è vuota'))
              : ReorderableListView.builder(
                  itemCount: queue.length,
                  onReorder: manager.reorderQueue,
                  itemBuilder: (context, index) {
                    final song = queue[index];
                    return Container(
                      key: ValueKey('${song.id}_$index'),
                      color: index == manager.currentIndex ? const Color(0xFF242424) : null,
                      child: SongListTile(
                        song: song,
                        isPlaying: index == manager.currentIndex,
                        onTap: () => manager.playFromQueueAt(index),
                        onRemove: () => manager.removeFromQueue(index),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

// =========================================================================
// PLAYLISTS SCREEN
// =========================================================================

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  Future<void> _createPlaylistDialog(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nuova playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nome della playlist'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Crea')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty && context.mounted) {
      context.read<PlayerManager>().createPlaylist(name.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerManager>(
      builder: (context, manager, _) {
        final names = manager.playlists.keys.toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Playlist')),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _createPlaylistDialog(context),
            child: const Icon(Icons.add),
          ),
          body: names.isEmpty
              ? const Center(child: Text('Nessuna playlist. Tocca + per crearne una.'))
              : ListView.builder(
                  itemCount: names.length,
                  itemBuilder: (context, index) {
                    final name = names[index];
                    final songs = manager.playlists[name] ?? [];
                    return ListTile(
                      leading: const Icon(Icons.playlist_play, size: 36),
                      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('${songs.length} brani'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => manager.deletePlaylist(name),
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlistName: name)),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

class PlaylistDetailScreen extends StatelessWidget {
  final String playlistName;
  const PlaylistDetailScreen({super.key, required this.playlistName});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerManager>(
      builder: (context, manager, _) {
        final songs = manager.playlists[playlistName] ?? [];
        return Scaffold(
          appBar: AppBar(
            title: Text(playlistName),
            actions: [
              if (songs.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => manager.playQueue(songs, 0),
                ),
            ],
          ),
          body: songs.isEmpty
              ? const Center(child: Text('Playlist vuota. Aggiungi brani dalla ricerca.'))
              : ListView.builder(
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return SongListTile(
                      song: song,
                      isPlaying: manager.currentSong?.id == song.id,
                      onTap: () => manager.playQueue(songs, index),
                      onRemove: () => manager.removeFromPlaylist(playlistName, song),
                    );
                  },
                ),
        );
      },
    );
  }
}
