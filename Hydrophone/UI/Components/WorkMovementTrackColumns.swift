// Cell text + sort support for issue #46's native-only Work, Movement Name,
// and Movement columns. Kept separate from ExpandedTrackColumns because that
// eight-column switch is already at the repository's complexity limit.

/// Roman-numeral conversion and the Title-column movement text derived for
/// rows under an active work header (issue #54). Free-standing so both
/// halves are unit-testable without a `Coordinator`.
enum WorkMovementTitle {
    private static let numerals: [(value: Int, symbol: String)] = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
        (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
        (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
    ]

    /// 1–3999 (the range plain roman numerals cover); values outside that
    /// return the plain decimal string rather than a malformed numeral.
    static func roman(_ number: Int) -> String {
        guard (1...3999).contains(number) else { return "\(number)" }
        var remaining = number
        var result = ""
        for (value, symbol) in numerals {
            while remaining >= value {
                result += symbol
                remaining -= value
            }
        }
        return result
    }

    /// Title text for a track row under an active work header. First rule
    /// that applies (see issue #54):
    /// 1. `movementNumber` present → "<roman>. <name>", name from
    ///    `movementName` or else the work-stripped title; skip the prefix if
    ///    that name already opens with a roman numeral (no double numbering).
    /// 2. No `movementNumber`, `title` begins with `work` → the remainder of
    ///    the title with that prefix (and separating whitespace/punctuation)
    ///    removed — preserves a tagger-written numeral.
    /// 3. `movementName` present → the bare name.
    /// 4. Otherwise → `title` unchanged.
    static func title(for song: Song) -> String {
        if let number = song.movementNumber {
            let namePart = song.movementName ?? strippedTitle(for: song) ?? song.title
            return startsWithRomanNumeral(namePart) ? namePart : "\(roman(number)). \(namePart)"
        }
        if let stripped = strippedTitle(for: song) {
            return stripped
        }
        if let movementName = song.movementName {
            return movementName
        }
        return song.title
    }

    /// Title-column text for a table row: the derived movement text under an
    /// active work header, the plain `title` everywhere else (issue #54's
    /// scope — Out: rows without their own `work` tag, or when no work
    /// header is showing at all).
    static func titleForRow(song: Song, workHeaderGroupingActive: Bool) -> String {
        guard workHeaderGroupingActive, song.work != nil else { return song.title }
        return title(for: song)
    }

    private static func strippedTitle(for song: Song) -> String? {
        guard let work = song.work, song.title.hasPrefix(work) else { return nil }
        var remainder = song.title.dropFirst(work.count)
        while let first = remainder.first, first.isWhitespace || first.isPunctuation {
            remainder.removeFirst()
        }
        return remainder.isEmpty ? nil : String(remainder)
    }

    private static func startsWithRomanNumeral(_ text: String) -> Bool {
        guard let boundary = text.firstIndex(where: { $0 == "." || $0.isWhitespace }) else { return false }
        let prefix = text[text.startIndex..<boundary]
        return !prefix.isEmpty && prefix.allSatisfy { "IVXLCDM".contains($0) }
    }
}

extension MusicTrackTable.Coordinator {
    func pickerOnlyColumnText(id: String, song: Song) -> String? {
        workMovementColumnText(id: id, song: song)
            ?? expandedColumnText(id: id, song: song)
    }

    private func workMovementColumnText(id: String, song: Song) -> String? {
        switch id {
        case "work": return song.work ?? "—"
        case "movementName": return song.movementName ?? "—"
        case "movement":
            guard let number = song.movementNumber, let total = song.movementTotal else { return "—" }
            return "\(number) of \(total)"
        default: return nil
        }
    }

    func pickerOnlyColumnOrderedBefore(
        id: String,
        lhs: Song,
        rhs: Song,
        ascending: Bool
    ) -> Bool? {
        workMovementColumnOrderedBefore(id: id, lhs: lhs, rhs: rhs, ascending: ascending)
            ?? expandedColumnOrderedBefore(id: id, lhs: lhs, rhs: rhs, ascending: ascending)
    }

    private func workMovementColumnOrderedBefore(
        id: String,
        lhs: Song,
        rhs: Song,
        ascending: Bool
    ) -> Bool? {
        func text(_ lhs: String?, _ rhs: String?) -> Bool {
            let comparison = (lhs ?? "").localizedCaseInsensitiveCompare(rhs ?? "")
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        func value<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): false
            case (nil, _): false
            case (_, nil): true
            case let (lhs?, rhs?): ascending ? lhs < rhs : lhs > rhs
            }
        }
        switch id {
        case "work": return text(lhs.work, rhs.work)
        case "movementName": return text(lhs.movementName, rhs.movementName)
        case "movement":
            // Matches the display guard above: a row needs both tags to show
            // a value, so a movement number without a total sorts as missing.
            return value(
                lhs.movementTotal != nil ? lhs.movementNumber : nil,
                rhs.movementTotal != nil ? rhs.movementNumber : nil
            )
        default: return nil
        }
    }
}
