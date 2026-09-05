import Foundation

extension LibraryMetadataStoreBatch {
    /// Favorite endpoints can omit expensive metadata. Their starred membership
    /// is authoritative, while omitted descriptive fields keep the richer row.
    static func preservingRichFields(_ value: Song, existing: Song) -> Song {
        var result = value
        result.artist = value.artist ?? existing.artist
        result.artistId = value.artistId ?? existing.artistId
        result.album = value.album ?? existing.album
        result.albumId = value.albumId ?? existing.albumId
        result.coverArt = value.coverArt ?? existing.coverArt
        result.duration = value.duration ?? existing.duration
        result.track = value.track ?? existing.track
        result.discNumber = value.discNumber ?? existing.discNumber
        result.year = value.year ?? existing.year
        result.genre = value.genre ?? existing.genre
        result.bitRate = value.bitRate ?? existing.bitRate
        result.suffix = value.suffix ?? existing.suffix
        result.contentType = value.contentType ?? existing.contentType
        result.size = value.size ?? existing.size
        result.genres = value.genres ?? existing.genres
        result.displayComposer = value.displayComposer ?? existing.displayComposer
        result.contributors = value.contributors ?? existing.contributors
        result.replayGain = value.replayGain ?? existing.replayGain
        result.displayAlbumArtist = value.displayAlbumArtist ?? existing.displayAlbumArtist
        result.comment = value.comment ?? existing.comment
        result.groupings = value.groupings ?? existing.groupings
        result.created = value.created ?? existing.created
        result.played = value.played ?? existing.played
        result.playCount = value.playCount ?? existing.playCount
        result.samplingRate = value.samplingRate ?? existing.samplingRate
        result.sortName = value.sortName ?? existing.sortName
        return result
    }

    static func preservingRichFields(_ value: Album, existing: Album) -> Album {
        var result = value
        result.artist = value.artist ?? existing.artist
        result.artistId = value.artistId ?? existing.artistId
        result.coverArt = value.coverArt ?? existing.coverArt
        result.songCount = value.songCount ?? existing.songCount
        result.duration = value.duration ?? existing.duration
        result.year = value.year ?? existing.year
        result.genre = value.genre ?? existing.genre
        result.genres = value.genres ?? existing.genres
        result.discTitles = value.discTitles ?? existing.discTitles
        return result
    }
}
