import SwiftUI

/// Composers as an imageless master-detail split. This issue supplies the
/// roster and a placeholder detail; the follow-up adds track actions.
struct ComposersView: View {
    @Environment(LibraryModel.self) private var library
    @AppStorage("composersSelectedID") private var selectedID: Composer.ID?
    @AppStorage("composersListWidth") private var listWidth = 240.0
    private static let listWidthRange = 180.0...360.0

    private var selected: Composer? {
        library.composers.first { $0.id == selectedID } ?? library.composers.first
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(library.composers) { composer in
                    let isSelected = composer.id == selectedID
                    HStack {
                        Text(composer.name).lineLimit(1)
                            .foregroundStyle(isSelected ? .white : .primary)
                        Spacer()
                        if let count = composer.songCount {
                            Text("\(count)").monospacedDigit()
                                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8))
                                                            : AnyShapeStyle(.secondary))
                        }
                    }
                    .tag(composer.id)
                    .listRowBackground(isSelected ? Color.accentColor : nil)
                }
            }
            .listStyle(.plain)
            .background(ListSelectionHighlightDisabler())
            .frame(width: listWidth)
            .overlay(alignment: .trailing) {
                PanelResizeHandle(width: $listWidth, range: Self.listWidthRange, anchoredEdge: .leading)
                    .offset(x: 5)
            }

            Divider()

            if let composer = selected {
                // swiftlint:disable:next todo
                // TODO(next sub-issue): real track list + play/shuffle/queue.
                VStack(alignment: .leading, spacing: 6) {
                    Text(composer.name).font(.largeTitle).bold()
                    if let count = composer.songCount {
                        Text("\(count) song\(count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("No Composers", systemImage: "person.2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await library.loadComposersIfNeeded()
            if selectedID == nil { selectedID = library.composers.first?.id }
        }
    }
}
