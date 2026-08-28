import AppKit

// Persistence for `MusicTrackTable`: the sort key/direction and (for stable
// library views) the scroll offset survive relaunches, keyed per view kind.

// MARK: - Sort persistence

extension MusicTrackTable.Coordinator {
    private var sortDefaultsKey: String? {
        parent.sortAutosaveKey.map { "trackSort.\($0)" }
    }

    func persistedSortDescriptor() -> NSSortDescriptor? {
        guard let key = sortDefaultsKey,
              let stored = UserDefaults.standard.string(forKey: key) else { return nil }
        let parts = stored.split(separator: "|")
        guard parts.count == 2 else { return nil }
        return NSSortDescriptor(key: String(parts[0]), ascending: parts[1] == "asc")
    }

    func initialSortDescriptor() -> NSSortDescriptor? {
        if let persisted = persistedSortDescriptor() { return persisted }
        return parent.defaultSortKey.map { NSSortDescriptor(key: $0, ascending: true) }
    }

    func persistSort(key sortKey: String?, ascending: Bool) {
        guard let key = sortDefaultsKey else { return }
        if let sortKey {
            UserDefaults.standard.set("\(sortKey)|\(ascending ? "asc" : "desc")", forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Scroll persistence

extension MusicTrackTable.Coordinator {
    private var scrollDefaultsKey: String? {
        parent.scrollAutosaveKey.map { "trackScroll.\($0)" }
    }

    /// Watch the clip view. Selector-based so no Sendable closure is needed
    /// (bounds notifications post on the main thread here) and the observer
    /// unregisters automatically when the coordinator deallocates.
    func observeScroll(of scroll: NSScrollView) {
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(userScrolled(_:)),
                                                   name: name, object: scroll)
        }
    }

    /// Live-scroll notifications identify user intent; plain bounds changes
    /// also occur during layout and must not consume a pending deep restore.
    @objc private func userScrolled(_ note: Notification) {
        guard let scroll = note.object as? NSScrollView else { return }
        scrollRestored = true
        scrollBoundsChanged(Notification(name: NSView.boundsDidChangeNotification,
                                         object: scroll.contentView))
    }

    /// Debounced save of the scroll offset. Saving only starts after the
    /// restore has run, so reload/restore churn can't clobber the stored value.
    @objc private func scrollBoundsChanged(_ note: Notification) {
        guard scrollRestored, let key = scrollDefaultsKey,
              let clipView = note.object as? NSClipView else { return }
        let offset = clipView.bounds.origin.y
        pendingScrollSave?.cancel()
        let work = DispatchWorkItem { UserDefaults.standard.set(offset, forKey: key) }
        pendingScrollSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Restore the persisted offset once rows arrive. A deep offset waits
    /// through partial snapshots; after loading finishes, a genuinely stale
    /// offset clamps to the final table height.
    func restoreScrollIfReady(_ scroll: NSScrollView) {
        guard let key = scrollDefaultsKey, !scrollRestored, !displayed.isEmpty,
              let doc = scroll.documentView else { return }
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 0 else {
            scrollRestored = true
            return
        }
        let maxOffset = max(doc.bounds.height - scroll.contentView.bounds.height, 0)
        guard !parent.contentIsLoading || saved <= maxOffset else { return }
        scrollRestored = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(saved, maxOffset)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
