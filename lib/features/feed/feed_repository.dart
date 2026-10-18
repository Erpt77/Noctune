import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/official_artwork_service.dart';
import '../../core/network/lastfm_api.dart';
import '../../core/storage/app_database.dart';
import '../downloads/download_manager.dart';
import '../innertube/innertube_api.dart';
import '../innertube/yt_library_providers.dart';
import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';
import '../library/playlists.dart';
import '../search/shared_providers.dart';
import 'local_taste.dart';

/// A generated/recommended track (Last.fm metadata + YTM resolution).
class GeneratedTrack {
  final String name;
  final String artist;
  final String album;
  final String artworkUrl;
  final String videoId;
  final String listeners;
  final String match;
  final int durationSeconds;

  const GeneratedTrack({
    required this.name,
    required this.artist,
    this.album = '',
    this.artworkUrl = '',
    this.videoId = '',
    this.listeners = '',
    this.match = '',
    this.durationSeconds = 0,
  });

  String get key => '${name.toLowerCase()}|${artist.toLowerCase()}';
}

/// A personalised, artist-anchored shelf on the LossWave home screen.
class DailyMix {
  final String title;
  final String seedArtist;
  final List<GeneratedTrack> tracks;

  const DailyMix({
    required this.title,
    required this.seedArtist,
    required this.tracks,
  });
}

/// Why a feed came back empty. Recorded by [FeedRepository] (which
/// knows which legs failed); the UI combines it with live connectivity
/// + auth state, so a non-network cause never says "offline".
enum FeedEmptyReason {
  /// Feed has content (or emptiness not evaluated).
  none,
  /// All sources answered, but there is no taste to rank (fresh
  /// profile, nothing liked/played, charts excluded away).
  noTaste,
  /// Last.fm legs threw despite a configured key (bad key, rate
  /// limit, transient API error). Never set when no key exists —
  /// skipped legs are not failures.
  lastfmError,
  /// YouTube charts failed and nothing else filled the page.
  chartsError,
  /// Last.fm AND charts both failed.
  allFailed,
  /// Device is offline (resolved UI-side via the network monitor).
  offline,
}

/// Personalised feed sections for the desktop home screen.
/// Mirrors LastWave-native `FeedRepository` section structure.
class FeedData {
  final List<GeneratedTrack> quickPicks;
  final List<GeneratedTrack> heavyRotation;
  final List<GeneratedTrack> freshFinds;
  final List<GeneratedTrack> jumpBackIn;
  final List<GeneratedTrack> becauseYouListened;
  final List<GeneratedTrack> charts;
  final List<String> tasteTags;

  /// Seed artist behind [becauseYouListened] ('' when the fallback
  /// pool was used). Rendered as "Because you listened to {seed}".
  final String becauseSeed;

  /// Normalized artist → raw affinity weight. Powers taste-ranked
  /// surfaces outside the feed (Discover new releases).
  final Map<String, double> tasteAffinities;

  /// Source-level failure flags behind [emptyReason]. `lastFmFailed`
  /// is only ever set when a key was configured (skipped legs are
  /// not failures); `chartsFailed` covers the charts leg.
  final bool lastFmFailed;
  final bool chartsFailed;

  /// Why the feed is empty ([FeedEmptyReason.none] when it isn't).
  final FeedEmptyReason emptyReason;

  const FeedData({
    this.quickPicks = const [],
    this.heavyRotation = const [],
    this.freshFinds = const [],
    this.jumpBackIn = const [],
    this.becauseYouListened = const [],
    this.charts = const [],
    this.tasteTags = const [],
    this.becauseSeed = '',
    this.tasteAffinities = const {},
    this.lastFmFailed = false,
    this.chartsFailed = false,
    this.emptyReason = FeedEmptyReason.none,
  });

  bool get isEmpty =>
      quickPicks.isEmpty &&
      heavyRotation.isEmpty &&
      freshFinds.isEmpty &&
      jumpBackIn.isEmpty &&
      becauseYouListened.isEmpty &&
      charts.isEmpty;
}

/// Resolve the final empty-state reason: a non-empty feed is never an
/// error, offline always wins (the device state beats leg outcomes),
/// otherwise the repository's recorded reason stands. Pure — unit
/// tested. `online` comes from the network monitor UI-side so the
/// repository stays offline-testable.
FeedEmptyReason resolveEmptyReason({
  required bool online,
  required FeedData data,
}) {
  if (!data.isEmpty) return FeedEmptyReason.none;
  if (!online) return FeedEmptyReason.offline;
  return data.emptyReason;
}

/// Day-boundary seed for the rotation RNG: same order all day
/// (stable, testable), fresh order tomorrow. See `loadFeed`.
int feedDaySeed(DateTime now) =>
    DateTime(now.year, now.month, now.day)
        .millisecondsSinceEpoch;

/// Stable key shared by local playback, likes, downloads and feed tracks.
String localTrackFeedbackKey(String name, String artist) =>
    '${name.toLowerCase().trim()}|${artist.toLowerCase().trim()}';

/// On-device feedback adjustment for recommendation ranking.
/// Likes are the strongest positive signal, downloads indicate ownership,
/// and repeated plays reinforce familiar tracks. Discovery shelves invert
/// the play-count signal so they introduce less recently replayed music.
double localTrackFeedbackScore(
  GeneratedTrack track, {
  Set<String> likedKeys = const <String>{},
  Set<String> downloadedKeys = const <String>{},
  Map<String, int> recentPlayCounts = const <String, int>{},
  bool discovery = false,
}) {
  final key = localTrackFeedbackKey(track.name, track.artist);
  final plays = recentPlayCounts[key] ?? 0;
  var score = 0.0;
  if (likedKeys.contains(key)) score += 16.0;
  if (downloadedKeys.contains(key)) score += 8.0;
  if (discovery) {
    score -= min(plays, 4) * 5.0;
  } else {
    score += min(plays, 4) * 2.5;
  }
  return score;
}
/// Canonical artist key for taste math: lowercase, collapsed space,
/// featured-credit and collaboration suffixes stripped (`feat./ft./featuring/with/x/&/vs` +
/// parenthesised variants), topic channels and junk mapped to ''. Pure — unit tested.
///
/// Without this, "A feat. B", "A x B", "A & C" split one artist's
/// weight and junk keys leak into taste tags.
String normalizeArtistKey(String artist) {
  var k = artist.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  if (k.isEmpty ||
      k == 'unknown artist' ||
      k == 'various artists' ||
      k == 'various' ||
      k == 'unknown' ||
      k == 'null' ||
      k == 'n/a') {
    return '';
  }
  // Strip YouTube "- Topic" channel tags
  k = k.replaceAll(RegExp(r'\s*-\s*topic$'), '').trim();

  // Parenthesised credits: "Artist (feat. X)", "[ft. X]", "(with X)"
  k = k
      .replaceAll(
          RegExp(r'\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with|prod\.?|produced by)\b[^\)\]]*[\)\]]', caseSensitive: false), '')
      .trim();

  // Trailing collab & featured credits: "A feat. B", "A ft B", "A featuring B", "A with B", "A prod. B"
  k = k
      .replaceAll(
          RegExp(r'\s+(feat\.?|ft\.?|featuring|with|prod\.?|produced by)\s+.+$'), '')
      .trim();

  // Collaboration separators: "A x B", "A X B", "A & B", "A vs B", "A vs. B"
  // Keep primary artist A so taste affinity concentrates on the primary artist
  k = k
      .replaceAll(RegExp(r'\s+([x&]|vs\.?)\s+.+$'), '')
      .trim();

  return k;
}
/// Drop banned tracks (exact `name|artist` key match). Pure — the
/// caller loads the set once per feed via `AppDatabase.loadExclusionKeys`.
List<GeneratedTrack> applyExclusions(
  List<GeneratedTrack> tracks,
  Set<String> excluded,
) {
  if (excluded.isEmpty) return tracks;
  return tracks.where((t) => !excluded.contains(t.key)).toList();
}

/// Rank global new releases by taste: known artists (normalized
/// affinity) first, everything else in original shelf order (explicit
/// index tiebreak — Dart sort is unstable). Pure — unit tested. Never
/// drops: unfamiliar records still browse below, just not ahead of
/// your artists.
List<YouTubeMusicEntity> rankNewReleases(
  List<YouTubeMusicEntity> albums,
  Map<String, double> affinities,
) {
  String artistOf(YouTubeMusicEntity a) =>
      a.artist.isNotEmpty ? a.artist : a.subtitle;
  final indexed = albums.asMap().entries.toList();
  indexed.sort((x, y) {
    final fa =
        affinities[normalizeArtistKey(artistOf(x.value))] ?? -1.0;
    final fb =
        affinities[normalizeArtistKey(artistOf(y.value))] ?? -1.0;
    final c = fb.compareTo(fa);
    if (c != 0) return c;
    return x.key.compareTo(y.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// Score-ordered pick with per-artist caps and key dedupe. Pure —
/// extracted for unit tests. Pass one [sharedCounts] map across
/// sections (in priority order) to cap artists page-wide.
List<GeneratedTrack> diversifyFeedTracks(
  List<({GeneratedTrack track, double score})> scored, {
  int limit = 18,
  int maxPerArtist = 2,
  Map<String, int>? sharedCounts,
}) {
  scored.sort((a, b) => b.score.compareTo(a.score));
  final counts = sharedCounts ?? <String, int>{};
  final out = <GeneratedTrack>[];
  final seen = <String>{};
    for (final entry in scored) {
      if (out.length >= limit) break;
      if (!seen.add(entry.track.key)) continue;
      final artist = normalizeArtistKey(entry.track.artist);
      if (artist.isEmpty) continue;
      if ((counts[artist] ?? 0) >= maxPerArtist) continue;
      counts[artist] = (counts[artist] ?? 0) + 1;
      out.add(entry.track);
    }
    return out;
  }

/// Drop items headlined by earlier sections, then register this
/// list's heads. Pure — extracted for unit tests.
List<GeneratedTrack> dedupeFeedHeads(
  List<GeneratedTrack> list,
  Set<String> headlined, {
  int headN = 3,
}) {
  final out =
      list.where((t) => !headlined.contains(t.key)).toList();
  headlined.addAll(out.take(headN).map((t) => t.key));
  return out;
}

/// Generation + feed repository.
///
/// Ports the scoring/diversification behaviour of Android
/// `FeedRepository` / `GenerateRepository` / `RecommendationEngine`
/// in compact form:
/// - affinity-weighted blending of Last.fm signals + YTM radio/charts
/// - per-artist caps, jitter, cross-source deduplication
class FeedRepository {
  final LastFmApiService _api;
  final InnerTubeMusicApi _tube;
  final HomeRepository _home;
  final String Function() _apiKey;
  final Random _random = Random();

  /// Local database for recommendation exclusions (nullable in unit
  /// tests — exclusions are simply skipped without it).
  final AppDatabase? _db;

  /// YouTube Music account signals (liked songs, watch history).
  /// Closure-injected so tests stay offline; each resolves to [] when
  /// signed out or on failure.
  final Future<List<YouTubeMusicTrack>> Function()? fetchYtLiked;
  final Future<List<YouTubeMusicTrack>> Function()? fetchYtHistory;

  /// Last.fm legs + charts leg, closure-injected for the same reason.
  /// Null means "call the real repository client" (production).
  /// Tests inject throwing/empty fakes to prove per-leg degradation.
  final Future<List<HomeTrack>> Function(int limit)? fetchLfmRecent;
  final Future<List<HomeTrack>> Function(String period, int limit)?
      fetchLfmTop;
  final Future<List<YouTubeMusicTrack>> Function(int limit)? fetchCharts;

  /// Discovery expansion per seed. Null means the built-in
  /// [_similarTracks] (YTM radio + Last.fm in parallel).
  final Future<List<GeneratedTrack>> Function(
      String name, String artist, int limit)? fetchSimilar;

  /// On-device taste (play log, liked songs, downloads). Null in unit
  /// tests without it — the feed then runs purely on account signals.
  final Future<LocalTaste?> Function()? fetchLocalTaste;

  FeedRepository(this._api, this._tube, this._home, this._apiKey,
      {this._db,
      this.fetchYtLiked,
      this.fetchYtHistory,
      this.fetchLfmRecent,
      this.fetchLfmTop,
      this.fetchCharts,
      this.fetchSimilar,
      this.fetchLocalTaste});

  List<Map<String, dynamic>> _asList(Object? v) {
    if (v is List) return v.whereType<Map<String, dynamic>>().toList();
    if (v is Map<String, dynamic>) return [v];
    return const [];
  }

  double _affinity(String artist, Map<String, double> affinities) =>
      affinities[normalizeArtistKey(artist)] ?? 0.0;

  List<GeneratedTrack> _diversify(
    List<({GeneratedTrack track, double score})> scored, {
    int limit = 18,
    int maxPerArtist = 2,
    // Shared across sections so one artist can't own the whole page:
    // pass the same map to every section in priority order and caps
    // apply page-wide while each section still fills to its limit.
    Map<String, int>? sharedCounts,
  }) =>
      diversifyFeedTracks(
        scored,
        limit: limit,
        maxPerArtist: maxPerArtist,
        sharedCounts: sharedCounts,
      );

  /// Remove items whose key already headlined an earlier section, then
  /// register this list's heads. Applied heavy → quick → fresh →
  /// because so the hero/companions can never echo the grids (and
  /// vice versa). History (jumpBackIn) and global charts are exempt —
  /// they mirror reality, not taste.
  List<GeneratedTrack> _dedupeHeads(
    List<GeneratedTrack> list,
    Set<String> headlined, {
    int headN = 3,
  }) =>
      dedupeFeedHeads(list, headlined, headN: headN);

  void _addAffinity(
    Map<String, double> affinities,
    String artist,
    double weight,
  ) {
    final k = normalizeArtistKey(artist);
    if (k.isEmpty) return;
    affinities[k] = (affinities[k] ?? 0) + weight;
  }

  Future<Map<String, double>> _artistAffinities(
    List<HomeTrack> top,
    List<HomeTrack> recent, {
    List<HomeTrack> longTerm = const [],
    List<YouTubeMusicTrack> ytLiked = const [],
    List<YouTubeMusicTrack> ytHistory = const [],
    List<HomeTrack> localLiked = const [],
    List<HomeTrack> localPlays = const [],
    List<HomeTrack> localDownloads = const [],
    // False when Last.fm contributed nothing (unconfigured or failed):
    // YT liked takes over the "top" slot and history the "recent"
    // slot. True keeps the historical weights, so connected feeds
    // never change flavor. `normAffinity` divides by the max, so the
    // blend self-renormalizes either way.
    bool lfmActive = true,
  }) async {
    final affinities = <String, double>{};
    for (var i = 0; i < top.length; i++) {
      _addAffinity(
          affinities, top[i].artist, 1.45 / (1 + i / 9));
    }
    for (var i = 0; i < recent.length; i++) {
      _addAffinity(
          affinities, recent[i].artist, 0.48 / (1 + i / 12));
    }
    // Long-term anchor: a spike week can't rewrite years of taste.
    for (var i = 0; i < longTerm.length; i++) {
      _addAffinity(
          affinities, longTerm[i].artist, 0.8 / (1 + i / 15));
    }
    // YouTube account signals: liked outweighs recent scrobbles, watch
    // history sits below them. Both trail Last.fm top — unless Last.fm
    // is absent, when liked takes the top slot and history the recent.
    for (var i = 0; i < ytLiked.length; i++) {
      _addAffinity(affinities, ytLiked[i].artist,
          (lfmActive ? 1.1 : 1.45) / (1 + i / 15));
    }
    for (var i = 0; i < ytHistory.length; i++) {
      _addAffinity(affinities, ytHistory[i].artist,
          (lfmActive ? 0.6 : 0.9) / (1 + i / 15));
    }
    // On-device signals: explicit local likes sit just under Last.fm
    // top (your collection outranks rented taste), downloads mark
    // ownership, the play log mirrors recent scrobbles. For keyless
    // guests these three ARE the algorithm.
    for (var i = 0; i < localLiked.length; i++) {
      _addAffinity(
          affinities, localLiked[i].artist, 1.3 / (1 + i / 12));
    }
    for (var i = 0; i < localDownloads.length; i++) {
      _addAffinity(
          affinities, localDownloads[i].artist, 0.9 / (1 + i / 15));
    }
    for (var i = 0; i < localPlays.length; i++) {
      _addAffinity(
          affinities, localPlays[i].artist, 0.5 / (1 + i / 12));
    }
    return affinities;
  }

  /// Build a playable, deduplicated queue of tracks similar to a chosen song.
  /// Uses the same YouTube Music radio + optional Last.fm source as the mixes.
  Future<List<GeneratedTrack>> fetchMoreLikeThis(
    String name,
    String artist, {
    int limit = 20,
  }) async {
    List<GeneratedTrack> candidates;
    try {
      final fetch = fetchSimilar;
      candidates = await (fetch != null
          ? fetch(name, artist, limit * 2)
          : _similarTracks(name, artist, limit: limit * 2))
          .timeout(const Duration(seconds: 14), onTimeout: () => <GeneratedTrack>[]);
    } catch (_) {
      candidates = <GeneratedTrack>[];
    }
    final seedKey = '${name.toLowerCase().trim()}|${artist.toLowerCase().trim()}';
    final seen = <String>{seedKey};
    final unique = candidates.where((t) =>
      t.name.trim().isNotEmpty &&
      t.artist.trim().isNotEmpty &&
      seen.add('${t.name.toLowerCase().trim()}|${t.artist.toLowerCase().trim()}')
    ).toList();
    final excluded = _db?.loadExclusionKeys() ?? const <String>{};
    final eligible = unique.where((t) =>
      !excluded.contains(AppDatabase.exclusionKey(t.name, t.artist))
    ).toList();
    if (eligible.isEmpty) return const <GeneratedTrack>[];
    final scored = eligible.map((t) => (
      track: t,
      score: (t.match.isEmpty ? 0 : double.tryParse(t.match) ?? 0) +
          _random.nextDouble() * 3,
    )).toList();
    final picked = _diversify(scored, limit: limit, maxPerArtist: 2);
    return resolveVideos(picked, limit: limit).timeout(
      const Duration(seconds: 30),
      onTimeout: () => picked,
    );
  }

  Future<List<GeneratedTrack>> _similarTracks(
    String name,
    String artist, {
    int limit = 12,
  }) async {
    final ytmFuture = () async {
      final ytmOut = <GeneratedTrack>[];
      try {
        final seed = await _tube
            .findBestMatchOrNull(name, artist)
            .timeout(const Duration(seconds: 4));
        if (seed != null) {
          final related = await _tube
              .fetchRelatedSongs(seed.videoId, limit: limit)
              .timeout(const Duration(seconds: 4));
          ytmOut.addAll(related.map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
              )));
        }
      } catch (_) {}
      return ytmOut;
    }();

    final lfmFuture = () async {
      final lfmOut = <GeneratedTrack>[];
      // No key, no call: without it the request can only fail, and
      // YTM radio above already covers expansion on its own.
      if (_apiKey().isEmpty) return lfmOut;
      try {
        final json = await _api.get({
          'method': 'track.getsimilar',
          'artist': artist,
          'track': name,
          'api_key': _apiKey(),
          'limit': '20',
          'autocorrect': '1',
        }).timeout(const Duration(seconds: 4));
        final similars = _asList(
            (json['similartracks'] as Map?)?['track']);
        for (final s in similars) {
          final n = s['name']?.toString() ?? '';
          final a = (s['artist'] as Map?)?['name']?.toString() ??
              s['artist']?.toString() ??
              '';
          if (n.isEmpty || a.isEmpty) continue;
          lfmOut.add(GeneratedTrack(
            name: n,
            artist: a,
            match: s['match']?.toString() ?? '',
          ));
        }
      } catch (_) {}
      return lfmOut;
    }();

    final results = await Future.wait([ytmFuture, lfmFuture]);
    return [...results[0], ...results[1]];
  }

  /// Resolve YTM videoIds for tracks missing them (bounded parallelism
  /// + per-item timeout + overall deadline returning partial results:
  /// an unresolved track keeps playing via search fallback, so stalls
  /// degrade instead of hanging Mix Lab forever).
  Future<List<GeneratedTrack>> resolveVideos(
    List<GeneratedTrack> tracks, {
    int limit = 30,
    Duration itemTimeout = const Duration(seconds: 10),
    Duration totalTimeout = const Duration(seconds: 40),
  }) async {
    final out = <GeneratedTrack>[];
    final queue = tracks.take(limit).toList();
    const batch = 4;
    Future<void> run() async {
      for (var i = 0; i < queue.length; i += batch) {
        final slice = queue.skip(i).take(batch).toList();
        final resolved = await Future.wait(slice.map((t) async {
          if (t.videoId.isNotEmpty) return t;
          try {
            final match = await _tube
                .findBestMatchOrNull(t.name, t.artist)
                .timeout(itemTimeout, onTimeout: () => null);
            if (match == null) return t;
            return GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album: t.album.isNotEmpty ? t.album : match.album,
              artworkUrl: t.artworkUrl.isNotEmpty
                  ? t.artworkUrl
                  : match.artworkUrl,
              videoId: match.videoId,
              listeners: t.listeners,
              match: t.match,
              durationSeconds: t.durationSeconds > 0
                  ? t.durationSeconds
                  : match.durationSeconds,
            );
          } catch (_) {
            return t;
          }
        }));
        out.addAll(resolved);
      }
    }

    try {
      await run().timeout(totalTimeout);
    } catch (_) {}
    return out;
  }

  /// Fill album/duration from a YouTube Music search when Last.fm omitted them.
  /// Never copies a videoId — a weak search hit here was playing the wrong song.
  Future<GeneratedTrack> fillMissingMetadata(GeneratedTrack t) async {
    if (t.durationSeconds > 0 && t.album.isNotEmpty) return t;
    try {
      final songs = await _tube.searchSongs(
        '${t.name} ${t.artist}',
        limit: 8,
      );
      YouTubeMusicTrack? hit;
      var best = -1;
      for (final s in songs) {
        final titleSim = InnerTubeMusicApi.similarity(
                InnerTubeMusicApi.baseTitle(s.title),
                InnerTubeMusicApi.baseTitle(t.name));
        if (titleSim < 85) continue;
        if (t.artist.isNotEmpty &&
            InnerTubeMusicApi.similarity(s.artist, t.artist) < 50) {
          continue;
        }
        if (titleSim > best) {
          best = titleSim;
          hit = s;
        }
      }
      if (hit == null) return t;
      return GeneratedTrack(
        name: t.name,
        artist: t.artist,
        album: t.album.isNotEmpty ? t.album : hit.album,
        artworkUrl:
            t.artworkUrl.isNotEmpty ? t.artworkUrl : hit.artworkUrl,
        videoId: t.videoId,
        listeners: t.listeners,
        match: t.match,
        durationSeconds: t.durationSeconds > 0
            ? t.durationSeconds
            : hit.durationSeconds,
      );
    } catch (_) {
      return t;
    }
  }

  /// New-release records (real albums/singles, no video items).
  /// Large pool (60): the shelf is global server-side, so taste
  /// ranking needs depth to find your artists inside it. Anonymous
  /// callers get the global shelf; connected callers get the
  /// server-personalized shelf via the authenticated browse.
  Future<List<YouTubeMusicEntity>> fetchNewReleaseAlbums(
      {int limit = 60}) async {
    try {
      return await _tube.browseAlbums(
        'FEmusic_new_releases',
        limit: limit,
      );
    } catch (_) {
      return const [];
    }
  }

  /// Resolve an album entity to playable tracks.
  Future<List<GeneratedTrack>> albumTracks(
      YouTubeMusicEntity album) async {
    if (album.browseId.isEmpty) return const [];
    try {
      final songs = await _tube.browseSongs(
        album.browseId,
        limit: 50,
      );
      final parts =
          InnerTubeMusicApi.splitSubtitle(album.subtitle);
      final artist =
          parts.length > 1 ? parts[1] : album.artist;
      return songs
          .map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist.isNotEmpty
                    ? t.artist
                    : artist,
                artworkUrl: t.artworkUrl.isNotEmpty
                    ? t.artworkUrl
                    : album.artworkUrl,
                videoId: t.videoId,
                album: t.album.isNotEmpty ? t.album : album.name,
                durationSeconds: t.durationSeconds,
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Personalized weekly new-music mix. The source is YouTube Music's
  /// dedicated new-releases browse; artist affinity and familiarity filters
  /// personalize it without inventing release dates that the API doesn't give.
  Future<DailyMix?> fetchReleaseRadar({int limit = 18}) async {
    Future<List<HomeTrack>> safeHome(
      Future<List<HomeTrack>> Function() load,
    ) async {
      try {
        return await load().timeout(const Duration(seconds: 10));
      } catch (_) {
        return <HomeTrack>[];
      }
    }

    final signals = await Future.wait<List<HomeTrack>>([
      safeHome(() {
        final fetch = fetchLfmTop;
        return fetch != null ? fetch('7day', 30) : _home.fetchTopTracks(period: '7day', limit: 30);
      }),
      safeHome(() {
        final fetch = fetchLfmRecent;
        return fetch != null ? fetch(30) : _home.fetchRecentTracks(limit: 30);
      }),
      safeHome(() {
        final fetch = fetchLfmTop;
        return fetch != null ? fetch('12month', 30) : _home.fetchTopTracks(period: '12month', limit: 30);
      }),
    ]);
    final weekly = signals[0];
    final recent = signals[1];
    final longTerm = signals[2];

    LocalTaste local = const LocalTaste();
    try {
      local = await (fetchLocalTaste?.call() ?? Future.value(null))
              .timeout(const Duration(seconds: 5)) ?? const LocalTaste();
    } catch (_) {}

    List<YouTubeMusicTrack> liked = const [];
    List<YouTubeMusicTrack> history = const [];
    try {
      liked = await (fetchYtLiked?.call() ?? Future.value(const <YouTubeMusicTrack>[]))
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
    try {
      history = await (fetchYtHistory?.call() ?? Future.value(const <YouTubeMusicTrack>[]))
          .timeout(const Duration(seconds: 6));
    } catch (_) {}

    List<YouTubeMusicEntity> albums;
    try {
      albums = await fetchNewReleaseAlbums(limit: 60).timeout(const Duration(seconds: 12));
    } catch (_) {
      return null;
    }
    if (albums.isEmpty) return null;

    final affinities = await _artistAffinities(
      weekly, recent, longTerm: longTerm, ytLiked: liked, ytHistory: history,
      localLiked: local.likedTracks, localPlays: local.recentPlays,
      localDownloads: local.downloadedTracks,
      lfmActive: weekly.isNotEmpty || recent.isNotEmpty,
    );
    final known = <String>{
      for (final t in [...recent, ...weekly, ...longTerm, ...local.seedPool(limit: 60)])
        '${t.name.toLowerCase().trim()}|${t.artist.toLowerCase().trim()}',
      for (final t in [...liked, ...history])
        '${t.title.toLowerCase().trim()}|${t.artist.toLowerCase().trim()}',
    };
    final excluded = _db?.loadExclusionKeys() ?? const <String>{};
    final weekSeed = feedDaySeed(DateTime.now()) ~/ 7;
    final ranked = albums.where((a) =>
        a.kind == YouTubeEntityKind.album && a.browseId.isNotEmpty).toList()
      ..sort((a, b) {
        final scoreA = _affinity(a.artist, affinities) * 100 + Random(weekSeed ^ a.name.hashCode).nextDouble();
        final scoreB = _affinity(b.artist, affinities) * 100 + Random(weekSeed ^ b.name.hashCode).nextDouble();
        return scoreB.compareTo(scoreA);
      });

    final candidates = <GeneratedTrack>[];
    final seen = <String>{};
    for (final album in ranked.take(12)) {
      List<GeneratedTrack> tracks;
      try {
        tracks = await albumTracks(album).timeout(const Duration(seconds: 8));
      } catch (_) {
        continue;
      }
      for (final track in tracks) {
        final key = '${track.name.toLowerCase().trim()}|${track.artist.toLowerCase().trim()}';
        if (track.name.trim().isEmpty || track.artist.trim().isEmpty ||
            known.contains(key) ||
            excluded.contains(AppDatabase.exclusionKey(track.name, track.artist)) ||
            !seen.add(key)) continue;
        candidates.add(track);
      }
      if (candidates.length >= limit * 2) break;
    }
    if (candidates.isEmpty) return null;

    final scored = candidates.map((track) => (
      track: track,
      score: _affinity(track.artist, affinities) * 30 +
          Random(weekSeed ^ track.key.hashCode).nextDouble() * 3,
    )).toList();
    final picked = _diversify(scored, limit: limit, maxPerArtist: 2);
    List<GeneratedTrack> playable;
    try {
      playable = await resolveVideos(picked, limit: limit)
          .timeout(const Duration(seconds: 30), onTimeout: () => picked);
    } catch (_) {
      playable = picked;
    }
    if (playable.isEmpty) return null;
    return DailyMix(title: 'Release Radar',
        seedArtist: 'New releases matched to your taste', tracks: playable);
  }

  Future<FeedData> loadFeed({bool chartsOnly = false}) async {
    try {
      Future<List<YouTubeMusicTrack>> cappedYt(
        Future<List<YouTubeMusicTrack>> Function()? fetch,
        int take,
      ) async {
        if (fetch == null) return const [];
        try {
          final list = await fetch()
              .timeout(const Duration(seconds: 12));
          return list.take(take).toList();
        } catch (_) {
          return const [];
        }
      }

      LocalTaste? localTaste;
      try {
        final fetch = fetchLocalTaste;
        if (fetch != null) {
          localTaste = await fetch()
              .timeout(const Duration(seconds: 5));
        }
      } catch (_) {
        localTaste = null;
      }
      final local = localTaste ?? const LocalTaste();

      // Last.fm is optional: without a user key its legs are skipped,
      // not attempted (no key means the call can only fail). A
      // present-but-bad key still degrades per-leg below — and per-leg
      // failures can never again discard YT results (every leg guards).
      // The LFM legs also get a deadline: previously an unbounded
      // Future.wait hung the whole Home on a stalled API call.
      final lfmReady = _apiKey().isNotEmpty;
      var lastFmFailed = false;
      Future<List<HomeTrack>> guardedLfm(
        Future<List<HomeTrack>> Function() fetch,
      ) async {
        if (!lfmReady) return const [];
        try {
          return await fetch()
              .timeout(const Duration(seconds: 12));
        } catch (_) {
          lastFmFailed = true;
          return const [];
        }
      }
      var chartsFailed = false;
      Future<List<YouTubeMusicTrack>> guardedCharts(int limit) async {
        try {
          final fetch = fetchCharts;
          if (fetch != null) {
            return await fetch(limit)
                .timeout(const Duration(seconds: 12));
          }
          return await _tube
              .browseSongs('FEmusic_charts', limit: limit)
              .timeout(const Duration(seconds: 12));
        } catch (_) {
          chartsFailed = true;
          return const [];
        }
      }

      final results = await Future.wait([
        guardedLfm(() {
          final fetch = fetchLfmRecent;
          return fetch != null
              ? fetch(30)
              : _home.fetchRecentTracks(limit: 30);
        }),
        guardedLfm(() {
          final fetch = fetchLfmTop;
          return fetch != null
              ? fetch('7day', 30)
              : _home.fetchTopTracks(period: '7day', limit: 30);
        }),
        guardedCharts(30),
        guardedLfm(() {
          final fetch = fetchLfmTop;
          return fetch != null
              ? fetch('12month', 30)
              : _home.fetchTopTracks(period: '12month', limit: 30);
        }),
        cappedYt(fetchYtLiked, 60),
        cappedYt(fetchYtHistory, 60),
      ]);
      final recent = results[0] as List<HomeTrack>;
      final top = results[1] as List<HomeTrack>;
      final charts = results[2] as List<YouTubeMusicTrack>;
      final longTerm = results[3] as List<HomeTrack>;
      final ytLiked = results[4] as List<YouTubeMusicTrack>;
      final ytHistory = results[5] as List<YouTubeMusicTrack>;
      // YT-only mode: Last.fm contributed nothing (unconfigured or
      // failed), so YT + local signals carry the feed. Drives the
      // dynamic reweight below and the YT candidate slots in heavy /
      // quick / jump-back.
      final lfmActive = top.isNotEmpty ||
          recent.isNotEmpty ||
          longTerm.isNotEmpty;
      final affinities = await _artistAffinities(
        top,
        recent,
        longTerm: longTerm,
        ytLiked: ytLiked,
        ytHistory: ytHistory,
        localLiked: local.likedTracks,
        localPlays: local.recentPlays,
        localDownloads: local.downloadedTracks,
        lfmActive: lfmActive,
      );
      // Banned tracks never surface, in any section.
      final excluded = _db?.loadExclusionKeys() ?? const <String>{};

      // Daily rotation salt: same order all day (stable, testable),
      // fresh order tomorrow. The old unseeded ±8 jitter could never
      // cross affinity gaps, so every boot rendered the same heads
      // until new scrobbles arrived.
      final rotation = Random(feedDaySeed(DateTime.now()));
      // Normalized affinity keeps every term comparable: affinity
      // 0–50, position 0–60 by boost, playback bonus ±, jitter 0–12.
      // Previously affinity×60 (0–300pts) buried the boost terms.
      final maxAffinity = affinities.values.fold<double>(
          0, (m, v) => v > m ? v : m);
      double normAffinity(String artist) =>
          maxAffinity <= 0 ? 0 : _affinity(artist, affinities) / maxAffinity;

      GeneratedTrack fromHome(HomeTrack t) => GeneratedTrack(
            name: t.name,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
          );
      GeneratedTrack fromYt(YouTubeMusicTrack t) => GeneratedTrack(
            name: t.title,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId,
          );

      List<GeneratedTrack> clean(List<GeneratedTrack> tracks) =>
          applyExclusions(tracks, excluded);

      final likedTrackKeys = local.likedTracks
          .map((t) => localTrackFeedbackKey(t.name, t.artist))
          .toSet();
      final downloadedTrackKeys = local.downloadedTracks
          .map((t) => localTrackFeedbackKey(t.name, t.artist))
          .toSet();
      final recentPlayCounts = <String, int>{};
      for (final t in local.recentPlays) {
        final key = localTrackFeedbackKey(t.name, t.artist);
        recentPlayCounts.update(key, (count) => count + 1,
            ifAbsent: () => 1);
      }

      List<({GeneratedTrack track, double score})> score(
        List<GeneratedTrack> tracks,
        double boost, {
        bool discovery = false,
      }) {
        return [
          for (var i = 0; i < tracks.length; i++)
            (
              track: tracks[i],
              score: normAffinity(tracks[i].artist) * 50 +
                  localTrackFeedbackScore(
                    tracks[i],
                    likedKeys: likedTrackKeys,
                    downloadedKeys: downloadedTrackKeys,
                    recentPlayCounts: recentPlayCounts,
                    discovery: discovery,
                  ) +
                  boost * 20 / (1 + i / 9) +
                  (tracks[i].videoId.isNotEmpty ? 4 : -2) +
                  rotation.nextDouble() * 12,
            ),
        ];
      }

      // One shared cap map in priority order: an artist topping the
      // charts can't also own every grid below.
      final pageCounts = <String, int>{};
      final heavy = _diversify(
        [
          ...score(clean(top.take(25).map(fromHome).toList()), 3.0),
          // Keyless guests have no Last.fm top — their liked songs
          // anchor Heavy Rotation instead.
          ...score(
              clean(local.likedTracks.take(10).map(fromHome).toList()),
              2.8),
          // YT-only: account liked songs take the top slot when
          // Last.fm is absent. Gated so connected feeds keep their
          // exact flavor.
          if (!lfmActive)
            ...score(
                clean(ytLiked.take(15).map(fromYt).toList()), 2.7),
        ],
        limit: 15,
        maxPerArtist: 2,
        sharedCounts: pageCounts,
      );
      final quick = _diversify(
        [
          ...score(clean(top.take(15).map(fromHome).toList()), 2.6),
          ...score(
              clean(recent.take(15).map(fromHome).toList()), 1.6),
          ...score(clean(charts.take(15).map(fromYt).toList()), 1.2),
          // YT-only: history fills the "recent" slot, liked the
          // "top" slot. Same gating as heavy above.
          if (!lfmActive)
            ...score(
                clean(ytLiked.take(15).map(fromYt).toList()), 2.4),
          if (!lfmActive)
            ...score(
                clean(ytHistory.take(15).map(fromYt).toList()), 1.6),
        ],
        limit: 18,
        sharedCounts: pageCounts,
      );

      // Discovery: expand distinct seed artists via similar tracks.
      // Seeds skip banned tracks — a ban means "not this", so its
      // neighborhood shouldn't seed either.
      bool banned(HomeTrack t) =>
          excluded.contains(AppDatabase.exclusionKey(t.name, t.artist));
      final seeds = <HomeTrack>[];
      final seenArtists = <String>{};
      HomeTrack ytSeed(YouTubeMusicTrack t) => HomeTrack(
            name: t.title,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
          );
      // Local pool seeds discovery for keyless guests (and enriches
      // it for everyone): recents, then liked, then downloads.
      // YT liked/history join the pool so a YT-only feed still has
      // seed artists when Last.fm is absent.
      for (final t in [
        ...top,
        ...recent,
        ...ytLiked.take(20).map(ytSeed),
        ...ytHistory.take(20).map(ytSeed),
        ...local.seedPool(limit: 8),
      ]) {
        if (banned(t)) continue;
        final k = normalizeArtistKey(t.artist);
        if (k.isEmpty || !seenArtists.add(k)) continue;
        seeds.add(t);
        if (seeds.length >= 4) break;
      }
      // No taste anywhere (fresh profile, signed out of everything):
      // seed discovery from the charts so Fresh Finds / Because can
      // still populate instead of rendering an empty page.
      if (seeds.isEmpty) {
        for (final c in charts.take(8)) {
          final t = ytSeed(c);
          if (banned(t)) continue;
          final k = normalizeArtistKey(t.artist);
          if (k.isEmpty || !seenArtists.add(k)) continue;
          seeds.add(t);
          if (seeds.length >= 4) break;
        }
      }
      final discovery = <GeneratedTrack>[];
      final discoveryBatches = await Future.wait(
        seeds.map(
          (seed) {
            final similar = fetchSimilar;
            final work = similar != null
                ? similar(seed.name, seed.artist, 8)
                : _similarTracks(seed.name, seed.artist,
                    limit: 8);
            return work.timeout(const Duration(seconds: 4),
                onTimeout: () =>
                    const <GeneratedTrack>[]);
          },
        ),
      );
      for (final batch in discoveryBatches) {
        discovery.addAll(batch);
      }
      final fresh = _diversify(
        score(applyExclusions(discovery, excluded), 2.0,
            discovery: true),
        limit: 12,
        maxPerArtist: 1,
        sharedCounts: pageCounts,
      );

      final jumpBack = _diversify(
        [
          ...score(
              recent
                  .where((t) => !banned(t))
                  .take(20)
                  .map(fromHome)
                  .toList(),
              2.0),
          // On-device play log: guests jump back into what they
          // actually played, no account required.
          ...score(
              local.recentPlays
                  .where((t) => !banned(t))
                  .take(20)
                  .map(fromHome)
                  .toList(),
              1.8),
          // YT-only: watch history fills the "recent" slot.
          if (!lfmActive)
            ...score(
                ytHistory
                    .where((t) => !excluded.contains(
                        AppDatabase.exclusionKey(
                            t.title, t.artist)))
                    .take(20)
                    .map(fromYt)
                    .toList(),
                1.8),
        ],
        limit: 12,
      );

      // Because You Listened, honestly: the batch whose seed carries
      // the strongest affinity wins, and its artist names the section.
      // Falls back to the old reversed-pool mix when seeds starve.
      String becauseSeed = '';
      List<GeneratedTrack> becausePool = const [];
      var seeded = false;
      if (seeds.isNotEmpty) {
        var best = -1.0;
        var bestBatch = -1;
        for (var b = 0; b < seeds.length && b < discoveryBatches.length; b++) {
          final aff = normAffinity(seeds[b].artist);
          if (aff > best) {
            best = aff;
            bestBatch = b;
          }
        }
        if (bestBatch >= 0 &&
            discoveryBatches[bestBatch].isNotEmpty) {
          becausePool = discoveryBatches[bestBatch];
          becauseSeed = seeds[bestBatch].artist;
          seeded = true;
        }
      }
      if (!seeded) {
        becausePool = discovery.reversed.take(20).toList();
        becauseSeed = '';
      }
      final because = _diversify(
        score(applyExclusions(becausePool, excluded), 2.2,
            discovery: true),
        limit: 12,
        maxPerArtist: 1,
        sharedCounts: pageCounts,
      );

      // Cross-section heads: the hero, companions and every grid head
      // must be distinct tracks — previously heavy[0] == quick[0]
      // rendered the same song 3–4 times per page (hero + up-next +
      // grid). History and global charts are exempt (mirrors, not picks).
      final headlined = <String>{};
      final dedupedHeavy = _dedupeHeads(heavy, headlined);
      final dedupedQuick = _dedupeHeads(quick, headlined);
      final dedupedFresh = _dedupeHeads(fresh, headlined);
      final dedupedBecause = _dedupeHeads(because, headlined);

      // Bulletproof per-track hydration: Apple studio -> strict YTM ->
      // loose YTM (artwork-only). A tile must NEVER stay empty when any
      // provider has the sleeve (regional / Devanagari tracks often miss
      // the iTunes US catalog). Order preserved by Future.wait;
      // OfficialArtworkService throttles internally (concurrency 3).
      Future<GeneratedTrack> hydrateOne(
          int i, GeneratedTrack t, int limit) async {
        if (i >= limit || t.artworkUrl.isNotEmpty || t.name.isEmpty) {
          return t;
        }
        // 1. Official studio cover (Apple/iTunes 1400x1400).
        try {
          final art = await OfficialArtworkService.instance
              .resolveOfficialArtwork(title: t.name, artist: t.artist)
              .timeout(const Duration(milliseconds: 1500));
          if (art != null && art.artworkUrl.isNotEmpty) {
            return GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album: t.album,
              artworkUrl: art.artworkUrl,
              videoId: t.videoId,
              listeners: t.listeners,
              match: t.match,
              durationSeconds: t.durationSeconds,
            );
          }
        } catch (_) {}
        // 2. Strict YTM match — artwork + videoId/album/duration fill
        // when the feed track lacks them (never overwrite real data).
        // Strict thresholds (72 title / 50 artist) keep playback safe.
        try {
          final match = await _tube
              .findBestMatchOrNull(t.name, t.artist)
              .timeout(const Duration(seconds: 2), onTimeout: () => null);
          if (match != null && match.artworkUrl.isNotEmpty) {
            return GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album:
                  t.album.isNotEmpty ? t.album : match.album,
              artworkUrl: match.artworkUrl,
              videoId: t.videoId.isNotEmpty
                  ? t.videoId
                  : match.videoId,
              listeners: t.listeners,
              match: t.match,
              durationSeconds: t.durationSeconds > 0
                  ? t.durationSeconds
                  : match.durationSeconds,
            );
          }
        } catch (_) {}
        // 3. Loose YTM artwork-only last resort — display-only, never
        // cached as a playback match and never copies videoId (a close
        // sleeve beats initials, but must not misroute playback).
        // Bar is deliberately low (>=60 title sim, no artist gate) so
        // transliterated / featured-credit variants still match.
        try {
          final songs = await _tube
              .searchSongs('${t.name} ${t.artist}', limit: 8)
              .timeout(const Duration(seconds: 2),
                  onTimeout: () => <YouTubeMusicTrack>[]);
          YouTubeMusicTrack? loose;
          var looseScore = -1;
          for (final s in songs) {
            if (s.artworkUrl.isEmpty) continue;
            final sim = InnerTubeMusicApi.similarity(
              InnerTubeMusicApi.baseTitle(s.title),
              InnerTubeMusicApi.baseTitle(t.name),
            );
            if (sim < 60) continue;
            if (sim > looseScore) {
              looseScore = sim;
              loose = s;
            }
          }
          loose ??= songs.cast<YouTubeMusicTrack?>().firstWhere(
                (s) => s != null && s.artworkUrl.isNotEmpty,
                orElse: () => null,
              );
          if (loose != null && loose.artworkUrl.isNotEmpty) {
            return GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album: t.album,
              artworkUrl: loose.artworkUrl,
              videoId: t.videoId,
              listeners: t.listeners,
              match: t.match,
              durationSeconds: t.durationSeconds,
            );
          }
        } catch (_) {}
        return t;
      }

      Future<List<GeneratedTrack>> hydrateArtwork(
          List<GeneratedTrack> list, {int limit = 6}) async {
        return Future.wait([
          for (var i = 0; i < list.length; i++)
            hydrateOne(i, list[i], limit),
        ]);
      }

      // Per-list guard (no all-or-nothing): one slow shelf falls back to
      // its unhydrated list while the other shelves still apply.
      Future<List<GeneratedTrack>> guardHydrate(
        Future<List<GeneratedTrack>> work,
        List<GeneratedTrack> fallback,
      ) async {
        try {
          return await work.timeout(const Duration(seconds: 6));
        } catch (_) {
          return fallback;
        }
      }

      var finalQuick = dedupedQuick;
      var finalHeavy = dedupedHeavy;
      var finalFresh = dedupedFresh;
      var finalBecause = dedupedBecause;
      var finalJump = jumpBack;
      if (!chartsOnly) {
        final hydrated = await Future.wait([
          guardHydrate(
              hydrateArtwork(dedupedQuick, limit: 8), dedupedQuick),
          guardHydrate(
              hydrateArtwork(dedupedHeavy, limit: 6), dedupedHeavy),
          guardHydrate(hydrateArtwork(jumpBack, limit: 6), jumpBack),
          guardHydrate(
              hydrateArtwork(dedupedFresh, limit: 6), dedupedFresh),
          guardHydrate(
              hydrateArtwork(dedupedBecause, limit: 6), dedupedBecause),
        ]);
        finalQuick = hydrated[0];
        finalHeavy = hydrated[1];
        finalJump = hydrated[2];
        finalFresh = hydrated[3];
        finalBecause = hydrated[4];
      }

      final feedCharts = applyExclusions(
          charts.take(15).map(fromYt).toList(), excluded);
      final quickOut = chartsOnly ? const <GeneratedTrack>[] : finalQuick;
      final heavyOut = chartsOnly ? const <GeneratedTrack>[] : finalHeavy;
      final freshOut = chartsOnly ? const <GeneratedTrack>[] : finalFresh;
      final jumpOut = chartsOnly ? const <GeneratedTrack>[] : finalJump;
      final becauseOut =
          chartsOnly ? const <GeneratedTrack>[] : finalBecause;
      // Empty-state reason from the legs that decided the outcome:
      // skipped Last.fm legs (no key) are not failures, so a keyless
      // feed can only report chartsError / noTaste — never lastfmError.
      final isFeedEmpty = quickOut.isEmpty &&
          heavyOut.isEmpty &&
          freshOut.isEmpty &&
          jumpOut.isEmpty &&
          becauseOut.isEmpty &&
          feedCharts.isEmpty;
      final reason = !isFeedEmpty
          ? FeedEmptyReason.none
          : lastFmFailed && chartsFailed
              ? FeedEmptyReason.allFailed
              : lastFmFailed
                  ? FeedEmptyReason.lastfmError
                  : chartsFailed
                      ? FeedEmptyReason.chartsError
                      : FeedEmptyReason.noTaste;
      return FeedData(
        quickPicks: quickOut,
        heavyRotation: heavyOut,
        freshFinds: freshOut,
        jumpBackIn: jumpOut,
        becauseYouListened: becauseOut,
        becauseSeed: becauseSeed,
        charts: feedCharts,
        tasteTags: affinities.keys.take(8).toList(),
        tasteAffinities: affinities,
        lastFmFailed: lastFmFailed,
        chartsFailed: chartsFailed,
        emptyReason: reason,
      );
    } catch (_) {
      // Last-resort fallback (something above threw outside the
      // guarded legs): charts only, honoring the injected seam.
      try {
        final fetch = fetchCharts;
        final fallbackCharts = fetch != null
            ? await fetch(15)
                .timeout(const Duration(seconds: 12))
            : await _tube
                .browseSongs('FEmusic_charts', limit: 15)
                .timeout(const Duration(seconds: 12));
        final mapped = fallbackCharts
            .map((t) => GeneratedTrack(
                  name: t.title,
                  artist: t.artist,
                  artworkUrl: t.artworkUrl,
                  videoId: t.videoId,
                ))
            .toList();
        return FeedData(
          charts: mapped,
          emptyReason: mapped.isEmpty
              ? FeedEmptyReason.chartsError
              : FeedEmptyReason.none,
        );
      } catch (_) {
        return const FeedData(
            emptyReason: FeedEmptyReason.allFailed);
      }
    }
  }

  /// Personal mix from taste: seed from YT history (current taste
  /// first) then YT liked, then the on-device pool (play log, liked,
  /// downloads) — keyless guests mix purely local. Picked with the
  /// daily rotation salt, expanded via YTM radio. Returns the seed
  /// plus the radio list, or null when the pool is empty / stalled —
  /// callers fall back to the feed hero. All network legs are capped.
  Future<({GeneratedTrack seed, List<GeneratedTrack> tracks})?>
      fetchPersonalMix({int limit = 20}) async {
    try {
      Future<List<YouTubeMusicTrack>> cappedYt(
        Future<List<YouTubeMusicTrack>> Function()? fetch,
        int take,
      ) async {
        if (fetch == null) return const [];
        try {
          final list = await fetch()
              .timeout(const Duration(seconds: 12));
          return list.take(take).toList();
        } catch (_) {
          return const [];
        }
      }

      final liked = await cappedYt(fetchYtLiked, 40);
      final history = await cappedYt(fetchYtHistory, 40);
      LocalTaste? mixLocal;
      try {
        final fetch = fetchLocalTaste;
        if (fetch != null) {
          mixLocal = await fetch()
              .timeout(const Duration(seconds: 5));
        }
      } catch (_) {
        mixLocal = null;
      }
      final pool =
          <({String title, String artist, String videoId, String art})>[];
      final seen = <String>{};
      void addSeed(
          String title, String artist, String videoId, String art) {
        final key =
            '${title.toLowerCase()}|${artist.toLowerCase()}';
        if (title.isEmpty || !seen.add(key)) return;
        pool.add(
            (title: title, artist: artist, videoId: videoId, art: art));
      }

      for (final t in [...history, ...liked]) {
        addSeed(t.title, t.artist, t.videoId, t.artworkUrl);
      }
      // On-device seeds: keyless guests mix from their play log and
      // liked songs (videoIds resolve via the match fallback below).
      for (final t in (mixLocal ?? const LocalTaste())
          .seedPool(limit: 12)) {
        addSeed(t.name, t.artist, '', t.artworkUrl);
      }
      if (pool.isEmpty) return null;
      final rotation = Random(feedDaySeed(DateTime.now()));
      final seed = pool[rotation.nextInt(pool.length)];
      var seedId = seed.videoId;
      var seedArt = seed.art;
      if (seedId.isEmpty) {
        final match = await _tube
            .findBestMatchOrNull(seed.title, seed.artist)
            .timeout(const Duration(seconds: 8),
                onTimeout: () => null);
        seedId = match?.videoId ?? '';
        if (seedArt.isEmpty) seedArt = match?.artworkUrl ?? '';
      }
      if (seedId.isEmpty) return null;
      final radio = await _tube
          .fetchRelatedSongs(seedId, limit: limit + 5)
          .timeout(const Duration(seconds: 8));
      final tracks = <GeneratedTrack>[];
      final trackSeen = {
        '${seed.title.toLowerCase()}|${seed.artist.toLowerCase()}'
      };
      for (final t in radio) {
        final key =
            '${t.title.toLowerCase()}|${t.artist.toLowerCase()}';
        if (t.title.isEmpty || !trackSeen.add(key)) continue;
        tracks.add(GeneratedTrack(
          name: t.title,
          artist: t.artist,
          artworkUrl: t.artworkUrl,
          videoId: t.videoId,
        ));
        if (tracks.length >= limit) break;
      }
      if (tracks.isEmpty) return null;
      return (
        seed: GeneratedTrack(
          name: seed.title,
          artist: seed.artist,
          artworkUrl: seedArt,
          videoId: seedId,
        ),
        tracks: tracks,
      );
    } catch (_) {
      return null;
    }
  }

  /// Generate a 30–35 track mood mix from taste signals.
  /// Mirrors `GenerateRepository.fetchMix` bucket weighting.
  Future<List<GeneratedTrack>> fetchMix({int total = 32}) async {
    final recent = await _home
        .fetchRecentTracks(limit: 20)
        .catchError((_) => <HomeTrack>[]);
    final top = await _home
        .fetchTopTracks(limit: 20)
        .catchError((_) => <HomeTrack>[]);
    final excluded = _db?.loadExclusionKeys() ?? const <String>{};
    bool banned(HomeTrack t) =>
        excluded.contains(AppDatabase.exclusionKey(t.name, t.artist));
    LocalTaste? mixLocalTaste;
    try {
      final fetch = fetchLocalTaste;
      if (fetch != null) {
        mixLocalTaste = await fetch()
            .timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      mixLocalTaste = null;
    }
    final poolSeeds = [
      ...recent.where((t) => !banned(t)).take(3),
      ...top.where((t) => !banned(t)).take(3),
      // On-device seeds keep Mix Lab personal without any account.
      ...(mixLocalTaste ?? const LocalTaste())
          .seedPool(limit: 6)
          .where((t) => !banned(t)),
    ];
    final pooledBatches = await Future.wait(
      poolSeeds.map(
        (t) => _similarTracks(t.name, t.artist)
            .timeout(const Duration(seconds: 8),
                onTimeout: () => <GeneratedTrack>[])
            .catchError((_) => <GeneratedTrack>[]),
      ),
    );
    final pooled = <GeneratedTrack>[
      for (final batch in pooledBatches) ...batch,
    ];
    if (pooled.isEmpty) {
      final charts =
          await _tube.browseSongs('FEmusic_charts', limit: total);
      return charts
          .map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
              ))
          .toList();
    }
    final longTerm = await _home
        .fetchTopTracks(period: '12month', limit: 20)
        .catchError((_) => <HomeTrack>[]);
    final mixLocal = mixLocalTaste ?? const LocalTaste();
    final affinities = await _artistAffinities(top, recent,
        longTerm: longTerm,
        localLiked: mixLocal.likedTracks,
        localPlays: mixLocal.recentPlays,
        localDownloads: mixLocal.downloadedTracks);
    final scored = pooled
        .map((t) => (
              track: t,
              score: _affinity(t.artist, affinities) * 30 +
                  _random.nextDouble() * 10,
            ))
        .toList();
    final picked =
        applyExclusions(_diversify(scored, limit: total, maxPerArtist: 2), excluded);
    return resolveVideos(picked, limit: total);
  }

  /// Build separate daily mixes from recent, weekly, long-term, and local
  /// listening signals. Each mix is anchored to a different artist, uses
  /// the same exclusion and diversification rules as the existing feed,
  /// and degrades gracefully when one data source is unavailable.
  Future<List<DailyMix>> fetchDailyMixes({
    int mixCount = 5,
    int tracksPerMix = 12,
  }) async {
    Future<List<HomeTrack>> safeHome(
      Future<List<HomeTrack>> Function() load,
    ) async {
      try {
        return await load().timeout(const Duration(seconds: 12));
      } catch (_) {
        return <HomeTrack>[];
      }
    }

    final signals = await Future.wait<List<HomeTrack>>([
      safeHome(() {
        final fetch = fetchLfmRecent;
        return fetch != null
            ? fetch(30)
            : _home.fetchRecentTracks(limit: 30);
      }),
      safeHome(() {
        final fetch = fetchLfmTop;
        return fetch != null
            ? fetch('7day', 30)
            : _home.fetchTopTracks(period: '7day', limit: 30);
      }),
      safeHome(() {
        final fetch = fetchLfmTop;
        return fetch != null
            ? fetch('12month', 30)
            : _home.fetchTopTracks(period: '12month', limit: 30);
      }),
    ]);

    final recent = signals[0];
    final weekly = signals[1];
    final longTerm = signals[2];

    LocalTaste local = const LocalTaste();
    try {
      final fetch = fetchLocalTaste;
      if (fetch != null) {
        local = await fetch().timeout(const Duration(seconds: 5)) ??
            const LocalTaste();
      }
    } catch (_) {}

    List<YouTubeMusicTrack> ytLiked = const [];
    List<YouTubeMusicTrack> ytHistory = const [];
    try {
      ytLiked = await (fetchYtLiked?.call() ?? Future.value(
        const <YouTubeMusicTrack>[],
      )).timeout(const Duration(seconds: 8));
    } catch (_) {}
    try {
      ytHistory = await (fetchYtHistory?.call() ?? Future.value(
        const <YouTubeMusicTrack>[],
      )).timeout(const Duration(seconds: 8));
    } catch (_) {}

    final excluded = _db?.loadExclusionKeys() ?? const <String>{};
    bool isExcluded(String name, String artist) =>
        excluded.contains(AppDatabase.exclusionKey(name, artist));

    final candidates = <HomeTrack>[
      ...recent,
      ...weekly,
      ...longTerm,
      ...local.seedPool(limit: 30),
    ];
    final seenTracks = <String>{};
    final unique = candidates.where((track) {
      if (track.name.trim().isEmpty || track.artist.trim().isEmpty) {
        return false;
      }
      if (isExcluded(track.name, track.artist)) return false;
      final key = '${track.name.toLowerCase().trim()}|${track.artist.toLowerCase().trim()}';
      return seenTracks.add(key);
    }).toList();

    // Rank seeds by a blended taste signal instead of randomly picking
    // artists. Recent listening gets a boost, weekly listening shapes the
    // current phase, and long-term taste keeps mixes from chasing one-week
    // obsessions. A day-seeded tie-break keeps the selection stable all day.
    final recentKeys = <String, int>{};
    final weeklyKeys = <String, int>{};
    final longTermKeys = <String, int>{};
    void indexSignals(List<HomeTrack> tracks, Map<String, int> target) {
      for (var i = 0; i < tracks.length; i++) {
        final key = normalizeArtistKey(tracks[i].artist);
        if (key.isNotEmpty) target.putIfAbsent(key, () => i);
      }
    }
    indexSignals(recent, recentKeys);
    indexSignals(weekly, weeklyKeys);
    indexSignals(longTerm, longTermKeys);
    final dayRandom = Random(feedDaySeed(DateTime.now()));
    double seedScore(HomeTrack track) {
      final artist = normalizeArtistKey(track.artist);
      final recentRank = recentKeys[artist];
      final weeklyRank = weeklyKeys[artist];
      final longRank = longTermKeys[artist];
      return (recentRank == null ? 0 : 2.2 / (1 + recentRank / 8)) +
          (weeklyRank == null ? 0 : 3.0 / (1 + weeklyRank / 10)) +
          (longRank == null ? 0 : 1.8 / (1 + longRank / 12)) +
          (local.likedTracks.any((t) =>
                  normalizeArtistKey(t.artist) == artist) ? 1.5 : 0) +
          (local.downloadedTracks.any((t) =>
                  normalizeArtistKey(t.artist) == artist) ? 0.7 : 0);
    }
    unique.sort((a, b) {
      final byTaste = seedScore(b).compareTo(seedScore(a));
      return byTaste != 0 ? byTaste : a.artist.compareTo(b.artist);
    });
    // Small deterministic daily rotation avoids the exact same order forever.
    final dayTieBreak = <String, double>{
      for (final track in unique)
        normalizeArtistKey(track.artist): dayRandom.nextDouble(),
    };
    unique.sort((a, b) {
      final byTaste = seedScore(b).compareTo(seedScore(a));
      if (byTaste != 0) return byTaste;
      return (dayTieBreak[normalizeArtistKey(b.artist)] ?? 0)
          .compareTo(dayTieBreak[normalizeArtistKey(a.artist)] ?? 0);
    });
    final seenArtists = <String>{};
    final seeds = unique.where((track) {
      final artist = normalizeArtistKey(track.artist);
      return artist.isNotEmpty && seenArtists.add(artist);
    }).take(mixCount).toList();

    if (seeds.isEmpty) return const <DailyMix>[];

    final affinities = await _artistAffinities(
      weekly,
      recent,
      longTerm: longTerm,
      ytLiked: ytLiked,
      ytHistory: ytHistory,
      localLiked: local.likedTracks,
      localPlays: local.recentPlays,
      localDownloads: local.downloadedTracks,
      lfmActive: weekly.isNotEmpty || recent.isNotEmpty,
    );

    final mixes = <DailyMix>[];
    // Prefer a different song set for each Daily Mix. A global key set
    // prevents the strongest recommendation sources from repeating the
    // same tracks across every artist-anchored mix.
    final tracksUsedByDailyMixes = <String>{};
    final dailyMixArtistCounts = <String, int>{};
    final dailyRotation = Random(feedDaySeed(DateTime.now()));
    for (final seed in seeds) {
      List<GeneratedTrack> similar;
      try {
        final fetch = fetchSimilar;
        final request = fetch != null
            ? fetch(seed.name, seed.artist, tracksPerMix * 3)
            : _similarTracks(seed.name, seed.artist, limit: tracksPerMix * 3);
        similar = await request.timeout(
          const Duration(seconds: 12),
          onTimeout: () => <GeneratedTrack>[],
        );
      } catch (_) {
        similar = <GeneratedTrack>[];
      }

      final seenSimilar = <String>{};
      final usable = similar.where((track) {
        if (track.name.trim().isEmpty || track.artist.trim().isEmpty) {
          return false;
        }
        if (isExcluded(track.name, track.artist)) return false;
        return seenSimilar.add(track.key);
      }).toList();

      // Source order is a weak similarity signal; artist affinity is
      // stronger. Stable daily jitter gives variety without reshuffling
      // the same mix every time Home rebuilds.
      final dailyJitter = <String, double>{
        for (final track in usable) track.key: dailyRotation.nextDouble(),
      };
      final scored = <({GeneratedTrack track, double score})>[];
      for (var i = 0; i < usable.length; i++) {
        final track = usable[i];
        final artist = normalizeArtistKey(track.artist);
        final alreadyUsed = tracksUsedByDailyMixes.contains(track.key);
        final repeatPenalty = alreadyUsed ? 28.0 : 0.0;
        final artistRepeatPenalty =
            (dailyMixArtistCounts[artist] ?? 0) * 8.0;
        final sourceRankBonus = 12.0 / (1 + i / 5);
        scored.add((
          track: track,
          score: _affinity(track.artist, affinities) * 30 +
              sourceRankBonus +
              (dailyJitter[track.key] ?? 0) * 1.5 -
              repeatPenalty -
              artistRepeatPenalty,
        ));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
      // First pass avoids songs used by earlier mixes. If a seed has a
      // small candidate pool, a second pass can reuse tracks rather than
      // leaving its mix empty.
      final freshScored = scored
          .where((entry) => !tracksUsedByDailyMixes.contains(entry.track.key))
          .toList();
      var picked = applyExclusions(
        _diversify(freshScored, limit: tracksPerMix, maxPerArtist: 2),
        excluded,
      );
      if (picked.length < tracksPerMix) {
        final pickedKeys = picked.map((track) => track.key).toSet();
        final refill = scored
            .where((entry) => !pickedKeys.contains(entry.track.key))
            .toList();
        picked = applyExclusions([
          ...picked,
          ..._diversify(
            refill,
            limit: tracksPerMix - picked.length,
            maxPerArtist: 2,
            sharedCounts: <String, int>{
              for (final track in picked)
                normalizeArtistKey(track.artist): 1,
            },
          ),
        ], excluded);
      }
      if (picked.isEmpty) continue;

      List<GeneratedTrack> playable;
      try {
        playable = await resolveVideos(
          picked,
          limit: tracksPerMix,
        ).timeout(
          const Duration(seconds: 35),
          onTimeout: () => picked,
        );
      } catch (_) {
        playable = picked;
      }

      if (playable.isNotEmpty) {
        tracksUsedByDailyMixes.addAll(playable.map((track) => track.key));
        for (final track in playable) {
          final artist = normalizeArtistKey(track.artist);
          if (artist.isNotEmpty) {
            dailyMixArtistCounts[artist] =
                (dailyMixArtistCounts[artist] ?? 0) + 1;
          }
        }
        mixes.add(DailyMix(
          title: 'Daily Mix ${mixes.length + 1}',
          seedArtist: seed.artist,
          tracks: playable,
        ));
      }
    }
    // "Discover Weekly": explore similar tracks from several of the
    // listener's strongest seeds, but deliberately remove tracks already
    // present in their recent, weekly, long-term, or local library signals.
    // A week-based seed keeps the order stable during the week.
    try {
      final knownKeys = <String>{
        for (final track in candidates)
          '${track.name.toLowerCase().trim()}|${track.artist.toLowerCase().trim()}',
        for (final track in ytLiked)
          '${track.title.toLowerCase().trim()}|${track.artist.toLowerCase().trim()}',
        for (final track in ytHistory)
          '${track.title.toLowerCase().trim()}|${track.artist.toLowerCase().trim()}',
      };
      final discoverySeeds = unique.take(6).toList();
      final batches = await Future.wait(discoverySeeds.map((seed) async {
        try {
          final fetch = fetchSimilar;
          final result = fetch != null
              ? await fetch(seed.name, seed.artist, tracksPerMix * 3)
              : await _similarTracks(seed.name, seed.artist,
                  limit: tracksPerMix * 3);
          return result;
        } catch (_) {
          return <GeneratedTrack>[];
        }
      })).timeout(
        const Duration(seconds: 14),
        onTimeout: () => <List<GeneratedTrack>>[],
      );
      final seenDiscovery = <String>{};
      final discoveryScored = <({GeneratedTrack track, double score})>[];
      for (final track in batches.expand((batch) => batch)) {
        if (track.name.trim().isEmpty || track.artist.trim().isEmpty) {
          continue;
        }
        final key =
            '${track.name.toLowerCase().trim()}|${track.artist.toLowerCase().trim()}';
        if (knownKeys.contains(key) || isExcluded(track.name, track.artist)) {
          continue;
        }
        if (!seenDiscovery.add(key)) continue;
        final artistAffinity = _affinity(track.artist, affinities);
        // Favor familiar sounds while keeping genuinely new artists eligible.
        discoveryScored.add((
          track: track,
          score: artistAffinity * 24 + _random.nextDouble() * 5,
        ));
      }
      final discovery = _diversify(
        discoveryScored,
        limit: tracksPerMix,
        maxPerArtist: 2,
      );
      if (discovery.isNotEmpty) {
        final playable = await resolveVideos(
          discovery,
          limit: tracksPerMix,
        ).timeout(
          const Duration(seconds: 35),
          onTimeout: () => discovery,
        );
        if (playable.isNotEmpty) {
          mixes.add(DailyMix(
            title: 'Discover Weekly',
            seedArtist: 'New tracks based on your taste',
            tracks: playable,
          ));
        }
      }
    } catch (_) {}

    // "On Repeat": tracks the listener returns to most often.
    try {
      final repeatSeeds = await safeHome(() {
        final fetch = fetchLfmTop;
        return fetch != null
            ? fetch('overall', 30)
            : _home.fetchTopTracks(period: 'overall', limit: 30);
      });
      final repeatTracks = <GeneratedTrack>[];
      final repeatSeen = <String>{};
      for (final track in repeatSeeds) {
        if (isExcluded(track.name, track.artist)) continue;
        final item = GeneratedTrack(
          name: track.name,
          artist: track.artist,
          artworkUrl: track.artworkUrl,
        );
        if (repeatSeen.add(item.key)) repeatTracks.add(item);
        if (repeatTracks.length >= tracksPerMix) break;
      }
      if (repeatTracks.isNotEmpty) {
        final playable = await resolveVideos(repeatTracks,
            limit: tracksPerMix).timeout(
          const Duration(seconds: 35),
          onTimeout: () => repeatTracks,
        );
        if (playable.isNotEmpty) {
          mixes.add(DailyMix(
            title: 'On Repeat',
            seedArtist: 'Your all-time favorites',
            tracks: playable,
          ));
        }
      }
    } catch (_) {}

    // Genre-special mixes: discover tags from top artists, then ask
    // Last.fm for tracks tagged with each genre or mood.
    if (_apiKey().isNotEmpty) {
      try {
        final artistSeeds = [...weekly, ...longTerm]
            .where((t) => t.artist.trim().isNotEmpty)
            .take(8);
        final tags = <String>{};
        for (final seed in artistSeeds) {
          try {
            final json = await _api.get({
              'method': 'artist.gettoptags',
              'artist': seed.artist,
              'api_key': _apiKey(),
              'autocorrect': '1',
            }).timeout(const Duration(seconds: 5));
            final root = json['toptags'] is Map
                ? Map<String, dynamic>.from(json['toptags'] as Map)
                : <String, dynamic>{};
            for (final tag in _asList(root['tag']).take(5)) {
              final name = tag['name']?.toString().trim() ?? '';
              if (name.isNotEmpty &&
                  !const {'seen live', 'favorites', 'favourite', 'my music'}
                      .contains(name.toLowerCase())) {
                tags.add(name);
              }
              if (tags.length >= 4) break;
            }
          } catch (_) {}
          if (tags.length >= 4) break;
        }

        for (final tag in tags.take(3)) {
          try {
            final json = await _api.get({
              'method': 'tag.gettoptracks',
              'tag': tag,
              'api_key': _apiKey(),
              'limit': '${tracksPerMix * 2}',
            }).timeout(const Duration(seconds: 7));
            final root = json['tracks'] is Map
                ? Map<String, dynamic>.from(json['tracks'] as Map)
                : <String, dynamic>{};
            final candidates = _asList(root['track'])
                .map((track) {
                  final artistValue = track['artist'];
                  final artist = artistValue is Map
                      ? (artistValue['name']?.toString() ?? '')
                      : artistValue?.toString() ?? '';
                  return GeneratedTrack(
                    name: track['name']?.toString() ?? '',
                    artist: artist,
                    artworkUrl: '',
                  );
                })
                .where((track) =>
                    track.name.isNotEmpty &&
                    track.artist.isNotEmpty &&
                    !isExcluded(track.name, track.artist))
                .toList();
            final deduped = <String>{};
            final genreScored = candidates
                .where((track) => deduped.add(track.key))
                .map((track) => (
                      track: track,
                      score: _affinity(track.artist, affinities) * 24 +
                          _random.nextDouble() * 5,
                    ))
                .toList();
            final genreTracks = _diversify(
              genreScored,
              limit: tracksPerMix,
              maxPerArtist: 2,
            );
            if (genreTracks.isEmpty) continue;
            final playable = await resolveVideos(genreTracks,
                limit: tracksPerMix).timeout(
              const Duration(seconds: 35),
              onTimeout: () => genreTracks,
            );
            if (playable.isNotEmpty) {
              final title =
                  '${tag[0].toUpperCase()}${tag.substring(1)} Mix';
              mixes.add(DailyMix(
                title: title,
                seedArtist: 'Genre picked for you',
                tracks: playable,
              ));
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    return mixes;
  }
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  // NOTE: closures below use ref.read, not ref.watch — they run when
  // the feed loads (long after this provider builds), where watch
  // throws. Read-at-call is also fresher (plays logged minutes ago).
  return FeedRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(innerTubeProvider),
    ref.watch(homeRepositoryProvider),
    () => ref.watch(prefsApiKeyProvider),
    db: ref.watch(databaseProvider),
    fetchYtLiked: () =>
        ref.read(ytLikedSongsProvider.future).catchError(
              (_) => const <YouTubeMusicTrack>[],
            ),
    fetchYtHistory: () =>
        ref.read(ytHistoryProvider.future).catchError(
              (_) => const <YouTubeMusicTrack>[],
            ),
    fetchLocalTaste: () async {
      try {
        final db = ref.read(databaseProvider);
        final plays = db
            .loadRecentPlays(limit: 100)
            .map((p) => HomeTrack(
                  name: p.title,
                  artist: p.artist,
                  timestampMillis: p.atMillis,
                ))
            .toList();
        final playlists = ref.read(playlistRepositoryProvider);
        final liked = <HomeTrack>[];
        for (final p in playlists) {
          if (!p.isLikedSongs) continue;
          for (final t in p.tracks) {
            if (t.name.isEmpty) continue;
            liked.add(HomeTrack(
              name: t.name,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
            ));
          }
        }
        final downloads = ref
            .read(downloadManagerProvider)
            .where((d) => d.status == DownloadStatus.done)
            .map((d) => HomeTrack(
                  name: d.title,
                  artist: d.artist,
                ))
            .where((t) => t.name.isNotEmpty)
            .toList();
        return LocalTaste(
          recentPlays: plays,
          likedTracks: liked,
          downloadedTracks: downloads,
        );
      } catch (_) {
        return null;
      }
    },
  );
});
