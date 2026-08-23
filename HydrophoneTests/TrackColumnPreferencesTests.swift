import Testing
import Foundation
@testable import Hydrophone

/// `TrackColumnPreferences` round-trips through an isolated UserDefaults
/// suite (never `.standard`, which would pollute the real app's prefs).
/// Each test uses its own `viewKind` string so tests never share keys and
/// don't need a teardown step to reset the suite.
struct TrackColumnPreferencesTests {
    private let defaults = UserDefaults(suiteName: "app.hydrophone.tests.TrackColumnPreferences")!

    @Test func columnsRoundTripInOrder() {
        let viewKind = "columnsRoundTripInOrder"
        TrackColumnPreferences.persistColumns([.artist, .title, .quality], for: viewKind, defaults: defaults)
        #expect(TrackColumnPreferences.persistedColumns(for: viewKind, defaults: defaults)
            == [.artist, .title, .quality])
    }

    @Test func persistedColumnsIsNilWhenNothingStored() {
        let viewKind = "persistedColumnsIsNilWhenNothingStored"
        #expect(TrackColumnPreferences.persistedColumns(for: viewKind, defaults: defaults) == nil)
    }

    @Test func unknownColumnIdIsDroppedNotCrashed() {
        let viewKind = "unknownColumnIdIsDroppedNotCrashed"
        defaults.set("title|noLongerACase|artist", forKey: "trackColumns.\(viewKind)")
        #expect(TrackColumnPreferences.persistedColumns(for: viewKind, defaults: defaults) == [.title, .artist])
    }

    @Test func persistedColumnsIsNilWhenEverythingStoredIsUnrecognized() {
        let viewKind = "persistedColumnsIsNilWhenEverythingStoredIsUnrecognized"
        defaults.set("retiredColumnA|retiredColumnB", forKey: "trackColumns.\(viewKind)")
        #expect(TrackColumnPreferences.persistedColumns(for: viewKind, defaults: defaults) == nil)
    }

    @Test func widthRoundTrips() {
        let viewKind = "widthRoundTrips"
        TrackColumnPreferences.persistWidth(212.5, for: "artist", in: viewKind, defaults: defaults)
        #expect(TrackColumnPreferences.persistedWidth(for: "artist", in: viewKind, defaults: defaults) == 212.5)
    }

    @Test func persistedWidthIsNilWhenNeverSet() {
        let viewKind = "persistedWidthIsNilWhenNeverSet"
        #expect(TrackColumnPreferences.persistedWidth(for: "artist", in: viewKind, defaults: defaults) == nil)
    }

    @Test func widthsAreIndependentPerColumnAndViewKind() {
        TrackColumnPreferences.persistWidth(100, for: "artist", in: "viewA", defaults: defaults)
        TrackColumnPreferences.persistWidth(200, for: "album", in: "viewA", defaults: defaults)
        TrackColumnPreferences.persistWidth(300, for: "artist", in: "viewB", defaults: defaults)
        #expect(TrackColumnPreferences.persistedWidth(for: "artist", in: "viewA", defaults: defaults) == 100)
        #expect(TrackColumnPreferences.persistedWidth(for: "album", in: "viewA", defaults: defaults) == 200)
        #expect(TrackColumnPreferences.persistedWidth(for: "artist", in: "viewB", defaults: defaults) == 300)
    }
}
