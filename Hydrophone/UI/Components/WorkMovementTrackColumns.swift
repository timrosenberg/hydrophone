// Cell text + sort support for issue #46's native-only Work, Movement Name,
// and Movement columns. Kept separate from ExpandedTrackColumns because that
// eight-column switch is already at the repository's complexity limit.

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
