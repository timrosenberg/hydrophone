import Testing
@testable import Hydrophone

/// Encoding/quality label shown on track rows and the Now Playing hero.
struct QualityLabelTests {
    @Test func losslessShowsFormatName() {
        #expect(Song(id: "1", title: "T", bitRate: 1024, suffix: "flac").qualityLabel == "FLAC")
        #expect(Song(id: "1", title: "T", bitRate: 1411, suffix: "wav").qualityLabel == "WAV")
        #expect(Song(id: "1", title: "T", suffix: "aif").qualityLabel == "AIFF")
    }

    @Test func lossyShowsBitRate() {
        #expect(Song(id: "1", title: "T", bitRate: 320, suffix: "mp3").qualityLabel == "320 kbps")
        #expect(Song(id: "1", title: "T", bitRate: 256, suffix: "m4a").qualityLabel == "256 kbps")
    }

    @Test func fallsBackToSuffixThenNil() {
        #expect(Song(id: "1", title: "T", suffix: "ogg").qualityLabel == "OGG")
        #expect(Song(id: "1", title: "T").qualityLabel == nil)
    }

    @Test func losslessRanksAboveAnyLossyBitRate() {
        let flac = Song(id: "1", title: "T", bitRate: 700, suffix: "flac")
        let mp3 = Song(id: "2", title: "T", bitRate: 320, suffix: "mp3")
        #expect(flac.qualityRank > mp3.qualityRank)
    }

    @Test func detailLabelAddsBitRateForLossless() {
        #expect(Song(id: "1", title: "T", bitRate: 1006, suffix: "flac").qualityDetailLabel == "FLAC · 1006 kbps")
    }

    @Test func detailLabelFallsBackToBareFormatWithoutBitRate() {
        #expect(Song(id: "1", title: "T", suffix: "flac").qualityDetailLabel == "FLAC")
        #expect(Song(id: "1", title: "T", bitRate: 0, suffix: "flac").qualityDetailLabel == "FLAC")
    }

    @Test func detailLabelMatchesQualityLabelForLossy() {
        let song = Song(id: "1", title: "T", bitRate: 320, suffix: "mp3")
        #expect(song.qualityDetailLabel == song.qualityLabel)
        #expect(song.qualityDetailLabel == "320 kbps")
    }

    @Test func detailLabelMatchesQualityLabelWithoutSuffix() {
        let song = Song(id: "1", title: "T")
        #expect(song.qualityDetailLabel == song.qualityLabel)
        #expect(song.qualityDetailLabel == nil)
    }

    @Test func detailLabelShowsBitDepthAndSampleRateWhenBothPresent() {
        var song = Song(id: "1", title: "T", bitRate: 998, suffix: "flac")
        song.samplingRate = 96_000
        song.bitDepth = 24
        #expect(song.qualityDetailLabel == "24/96k")
    }

    @Test func detailLabelRoundsSampleRateToOneDecimalWhenNotWholeKilohertz() {
        var song = Song(id: "1", title: "T", suffix: "flac")
        song.samplingRate = 44_100
        song.bitDepth = 16
        #expect(song.qualityDetailLabel == "16/44.1k")
    }

    @Test func detailLabelFallsBackToBitRateWhenBitDepthIsMissing() {
        // Plain Subsonic servers, or a Navidrome file without a decoded bit
        // depth — no broken/partial label, same as before #106.
        var song = Song(id: "1", title: "T", bitRate: 1006, suffix: "flac")
        song.samplingRate = 96_000
        #expect(song.qualityDetailLabel == "FLAC · 1006 kbps")
    }

    @Test func detailLabelFallsBackToBitRateWhenSampleRateIsMissing() {
        var song = Song(id: "1", title: "T", bitRate: 1006, suffix: "flac")
        song.bitDepth = 24
        #expect(song.qualityDetailLabel == "FLAC · 1006 kbps")
    }

    @Test func detailLabelIgnoresZeroBitDepth() {
        var song = Song(id: "1", title: "T", bitRate: 1006, suffix: "flac")
        song.samplingRate = 96_000
        song.bitDepth = 0
        #expect(song.qualityDetailLabel == "FLAC · 1006 kbps")
    }

    @Test func detailLabelBitDepthDoesNotAffectLossyFiles() {
        var song = Song(id: "1", title: "T", bitRate: 320, suffix: "mp3")
        song.bitDepth = 16 // never happens in practice, but must not leak into the label
        #expect(song.qualityDetailLabel == "320 kbps")
    }
}
