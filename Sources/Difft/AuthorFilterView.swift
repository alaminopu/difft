import SwiftUI
import DifftServices
import DifftUI

/// Opens the author picker and says how the list is currently narrowed.
struct AuthorFilterButton: View {
    @EnvironmentObject var model: AppModel
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: Spacing.xs) {
                Text(label)
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(.callout)
            .foregroundStyle(model.prAuthors.isEmpty ? Color.secondary : Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AuthorPicker()
                .environmentObject(model)
        }
        .help("Filter by author. Pick several to see all of their pull requests.")
        .accessibilityLabel("Filter by author")
    }

    private var label: String {
        switch model.prAuthors.count {
        case 0: return "Author"
        case 1: return model.prAuthors.first ?? "Author"
        default: return "\(model.prAuthors.count) authors"
        }
    }
}

/// A searchable, multi-select list of people.
///
/// A menu works for a handful of names and falls apart at two hundred: you
/// cannot scan it, and the person you want is usually not among the authors of
/// the page currently on screen. This searches the repository's whole
/// contributor list, and accepts a login that is not in it — a first-time
/// contributor has no commits on the default branch and so appears nowhere.
struct AuthorPicker: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = ""
    @FocusState private var searchFocused: Bool

    private var matches: [String] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.knownAuthors }
        return model.knownAuthors.filter { $0.lowercased().contains(q) }
    }

    /// A login the user typed that matches nobody known. Offered rather than
    /// rejected: the directory is contributors, not everyone who can open a PR,
    /// so a first-time contributor appears nowhere.
    ///
    /// Only when nothing matched — while a name is being typed, "audr" is a
    /// prefix of a real person, not a person, and offering it as one is noise.
    private var literal: String? {
        let typed = filter.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !typed.contains(" "), matches.isEmpty else { return nil }
        return typed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.knownAuthors.isEmpty, model.isLoadingAuthors {
                loading
            } else {
                results
            }
            if !model.prAuthors.isEmpty {
                Divider()
                footer
            }
        }
        .frame(width: 300)
        // Tall enough to scan a team in, not so tall it covers the list it is
        // filtering.
        .frame(minHeight: 260, maxHeight: 460)
        // A popover's own material is translucent, and the pull-request list
        // read straight through the names.
        .background(Palette.floating)
        .task {
            await model.loadAuthorDirectory()
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).imageScale(.small)
            TextField("Find a person", text: $filter)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if model.isLoadingAuthors {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 14, height: 14)
            } else if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private var loading: some View {
        HStack {
            Spacer()
            Text("Loading people…").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, Spacing.xl)
    }

    @ViewBuilder
    private var results: some View {
        // Selected people stay visible at the top even while a filter that
        // excludes them is typed, so nothing silently stays switched on
        // out of sight.
        let picked = model.prAuthors.sorted()
        let rest = matches.filter { !model.prAuthors.contains($0) }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(picked, id: \.self) { AuthorRow(login: $0, selected: true, toggle: toggle) }
                if !picked.isEmpty, !rest.isEmpty {
                    Divider().padding(.vertical, Spacing.xxs)
                }
                ForEach(rest, id: \.self) { AuthorRow(login: $0, selected: false, toggle: toggle) }
                if let literal {
                    Divider().padding(.vertical, Spacing.xxs)
                    AuthorRow(login: literal, selected: false, toggle: toggle,
                              note: "not a contributor — use anyway")
                }
                if rest.isEmpty, picked.isEmpty, literal == nil {
                    Text(model.knownAuthors.isEmpty ? "No people found" : "No match")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.lg)
                }
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    private var footer: some View {
        Button("Clear \(model.prAuthors.count) selected") { model.prAuthors = [] }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
    }

    private func toggle(_ login: String) {
        if model.prAuthors.contains(login) {
            model.prAuthors.remove(login)
        } else {
            model.prAuthors.insert(login)
            // Someone typed in by hand has to join the directory, or the row
            // vanishes the moment the filter is cleared.
            model.rememberAuthor(login)
        }
    }
}

private struct AuthorRow: View {
    let login: String
    let selected: Bool
    let toggle: (String) -> Void
    var note: String?
    @State private var hovering = false

    var body: some View {
        Button { toggle(login) } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(login).lineLimit(1)
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(login)\(selected ? ", selected" : "")")
    }
}
