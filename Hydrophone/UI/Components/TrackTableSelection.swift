import AppKit

extension MusicTrackTable.Coordinator {
    /// The public selection uses displayed indices. During pagination, retain
    /// the actual selected song identities as newly sorted pages shift them.
    func updateTracks(from updated: MusicTrackTable) -> Set<Int> {
        let wasLoading = parent.contentIsLoading || updated.contentIsLoading
        let previousOrder = displayed.map(\.id)
        let selectedIDs = Set((table?.selectedRowIndexes ?? []).compactMap { row in
            trackIndex(atRow: row).map { displayed[$0].id }
        })
        parent = updated
        updatingSelection = true
        reloadIfNeeded()
        updatingSelection = false
        if wasLoading && previousOrder != displayed.map(\.id) {
            let indices = Set(displayed.indices.filter { selectedIDs.contains(displayed[$0].id) })
            deferSelectionSave(indices)
        }
        return pendingSelection ?? parent.selection
    }

    /// AppKit updates immediately; defer the binding write until outside the
    /// representable update. A newer snapshot or user selection supersedes it.
    private func deferSelectionSave(_ indices: Set<Int>) {
        pendingSelectionSave?.cancel()
        pendingSelection = indices
        let work = DispatchWorkItem { [weak self] in
            guard let self, let selection = self.pendingSelection else { return }
            self.pendingSelection = nil
            self.parent.selection = selection
        }
        pendingSelectionSave = work
        DispatchQueue.main.async(execute: work)
    }
}
