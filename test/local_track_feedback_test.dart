import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.inMemory();
  });

  tearDown(() {
    db.raw.dispose();
  });

  test('records early skips and deliberate replays per normalized track', () {
    db.recordTrackSkip(title: 'Signal', artist: 'Artist');
    db.recordTrackSkip(title: 'Signal', artist: 'Artist');
    db.recordTrackReplay(title: ' signal ', artist: ' ARTIST ');

    final rows = db.loadTrackFeedback();
    expect(rows, hasLength(1));
    expect(rows.single.title, 'signal');
    expect(rows.single.artist, 'ARTIST');
    expect(rows.single.earlySkips, 2);
    expect(rows.single.replays, 1);
  });

  test('artist exclusions persist and use normalized artist keys', () {
    db.addArtistExclusion('  The Example  ');
    expect(
      db.loadExclusionKeys(),
      contains(AppDatabase.artistExclusionKey('the example')),
    );
    db.removeExclusion(AppDatabase.artistExclusionKey('THE EXAMPLE'));
    expect(
      db.loadExclusionKeys(),
      isNot(contains(AppDatabase.artistExclusionKey('the example'))),
    );
  });

  test('ignores blank track metadata and loads empty feedback safely', () {
    db.recordTrackSkip(title: ' ', artist: 'Artist');
    db.recordTrackReplay(title: 'Song', artist: '');
    expect(db.loadTrackFeedback(), isEmpty);
  });
}
