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

    @Test func detailLabelShowsBitDepthAndSampleRateAboveTheHiResThreshold() {
        var song = Song(id: "1", title: "T", bitRate: 998, suffix: "flac")
        song.samplingRate = 96_000
        song.bitDepth = 24
        #expect(song.qualityDetailLabel == "FLAC 24/96k")
    }

    @Test func detailLabelRoundsSampleRateToOneDecimalWhenNotWholeKilohertz() {
        var song = Song(id: "1", title: "T", bitRate: 1000, suffix: "flac")
        song.samplingRate = 44_100
        song.bitDepth = 16
        #expect(song.qualityDetailLabel == "FLAC 16/44.1k")
    }

    @Test func detailLabelUsesFormatPlusBitRateAtOrBelowTheHiResThreshold() {
        // Exactly at the 320 kbps threshold — "higher than 320" doesn't
        // include 320 itself, so this stays the kbps form even with bit
        // depth/sample rate present.
        var song = Song(id: "1", title: "T", bitRate: 320, suffix: "flac")
        song.samplingRate = 44_100
        song.bitDepth = 16
        #expect(song.qualityDetailLabel == "FLAC 320 kbps")
    }

    @Test func detailLabelFallsBackToBareFormatWithoutBitRate() {
        #expect(Song(id: "1", title: "T", suffix: "flac").qualityDetailLabel == "FLAC")
        #expect(Song(id: "1", title: "T", bitRate: 0, suffix: "flac").qualityDetailLabel == "FLAC")
    }

    @Test func detailLabelFallsBackToBitRateWhenBitDepthIsMissing() {
        // Plain Subsonic servers, or a Navidrome file without a decoded bit
        // depth — no broken/partial label, same as before #106.
        var song = Song(id: "1", title: "T", bitRate: 1006, suffix: "flac")
        song.samplingRate = 96_000
        #expect(song.qualityDetailLabel == "FLAC 1006 kbps")
    }

    @Test func detailLabelFallsBackToBitRateWhenSampleRateIsMissing() {
        var song = Song(id: "1", title: "T", bitRate: 1006, suffix: "flac")
        song.bitDepth = 24
        #expect(song.qualityDetailLabel == "FLAC 1006 kbps")
    }

    @Test func detailLabelIgnoresZeroBitDepth() {
        var song = Song(id: "1", title: "T", bitRate: 1006, suffix: "flac")
        song.samplingRate = 96_000
        song.bitDepth = 0
        #expect(song.qualityDetailLabel == "FLAC 1006 kbps")
    }

    @Test func detailLabelPrefixesLossyFilesWithTheCodecName() {
        // Unlike the compact Quality column, the Now Playing badge always
        // names the codec, even below the hi-res threshold.
        #expect(Song(id: "1", title: "T", bitRate: 192, suffix: "mp3").qualityDetailLabel == "MP3 192 kbps")
        #expect(Song(id: "1", title: "T", bitRate: 256, suffix: "aac").qualityDetailLabel == "AAC 256 kbps")
    }

    @Test func detailLabelHighBitRateLossySuffixWithoutBitDepthFallsBackToKbps() {
        // A suffix that isn't a known lossless format can still exceed the
        // threshold (e.g. a high-bitrate Opus/Vorbis stream); without a
        // reported bit depth there's nothing to show but the bit rate.
        #expect(Song(id: "1", title: "T", bitRate: 400, suffix: "ogg").qualityDetailLabel == "OGG 400 kbps")
    }

    @Test func detailLabelNamesM4AAsALACAboveTheHiResThresholdWithBitDepth() {
        // .m4a alone can't say ALAC vs. AAC — the hi-res branch is what
        // resolves it, since AAC never carries a bit depth.
        var song = Song(id: "1", title: "T", bitRate: 1000, suffix: "m4a")
        song.samplingRate = 44_100
        song.bitDepth = 16
        #expect(song.qualityDetailLabel == "ALAC 16/44.1k")
    }

    @Test func detailLabelNamesM4AAsAACBelowTheHiResThresholdOrWithoutBitDepth() {
        #expect(Song(id: "1", title: "T", bitRate: 256, suffix: "m4a").qualityDetailLabel == "AAC 256 kbps")
        // High bit rate but no bit depth reported — still AAC, not ALAC.
        #expect(Song(id: "1", title: "T", bitRate: 603, suffix: "m4a").qualityDetailLabel == "AAC 603 kbps")
    }

    @Test func detailLabelWithoutSuffixShowsBareBitRate() {
        #expect(Song(id: "1", title: "T", bitRate: 192).qualityDetailLabel == "192 kbps")
    }

    @Test func detailLabelWithoutSuffixOrBitRateIsNil() {
        #expect(Song(id: "1", title: "T").qualityDetailLabel == nil)
    }
}
