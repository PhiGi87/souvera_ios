// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Spotlight-artige Suche (Run 25.09.): schwebende Suchzeile + angehaengte,
// SCROLLBARE Ergebnisliste ueber abgedunkeltem Modul-Inhalt. Die Ergebnisse
// leben im Overlay und aktualisieren sich debounced live; NUR der Tap auf
// ein Ergebnis navigiert in die normale Ansicht. Der Suchzustand (Query +
// Ergebnisse) lebt beim Aufrufer und ueberlebt das Schliessen - der
// Header-Such-Button oeffnet das Overlay wieder an der alten Stelle.

import SwiftUI

/// Anzeigemodell einer Overlay-Zeile (generisch, Module mappen ihre
/// Domänenobjekte darauf; die Auswahl liefert das Domänenobjekt zurück).
struct SouveraSearchDisplay: Equatable {
    let title: String
    let subtitle: String
    let icon: String
    let tintColor: Color

    static func == (lhs: SouveraSearchDisplay, rhs: SouveraSearchDisplay) -> Bool {
        lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.icon == rhs.icon
    }
}

struct SouveraSearchOverlay<Item: Identifiable>: View {
    let title: String
    /// Hinweistext, wenn die Suche laeuft (z. B. "weite Kalendersuche").
    var loadingHint: String = ""
    @Binding var isPresented: Bool
    @Binding var query: String
    let items: [Item]
    let isLoading: Bool
    let display: (Item) -> SouveraSearchDisplay
    let onSelect: (Item) -> Void

    @FocusState private var fieldFocused: Bool
    @State private var scrolledQuery = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Abdunkelung: Tap daneben schliesst (Zustand bleibt erhalten).
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                searchBar
                resultList
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: - Suchzeile

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(title, text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button(NSLocalizedString("_cancel_", comment: "")) {
                isPresented = false
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Ergebnisliste (scrollbar)

    @ViewBuilder
    private var resultList: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                    if !loadingHint.isEmpty {
                        Text(loadingHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !trimmedQuery.isEmpty {
                    Text(NSLocalizedString("_mail_search_no_results_", comment: ""))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    Text(NSLocalizedString("_mail_search_hint_", comment: ""))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.bottom, 8)
        } else {
            ScrollViewReader { proxy in
                // Scrollbar bis zur Tastatur: die Hoehe ist begrenzt, der
                // Inhalt laesst sich voll durchscrollen; bei neuer Query
                // springt die Liste nach oben.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 1).id("souvera-search-top")
                        ForEach(items) { item in
                            rowButton(item)
                            Divider().padding(.leading, 54)
                        }
                        if isLoading, !loadingHint.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(loadingHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.55)
                .onChange(of: query) { _, _ in
                    // Neue Query: Liste startet wieder oben.
                    proxy.scrollTo("souvera-search-top", anchor: .top)
                }
                .onAppear {
                    if scrolledQuery != query {
                        scrolledQuery = query
                        proxy.scrollTo("souvera-search-top", anchor: .top)
                    }
                }
            }
        }
    }

    private func rowButton(_ item: Item) -> some View {
        let d = display(item)
        return Button {
            isPresented = false
            onSelect(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: d.icon)
                    .font(.body)
                    .foregroundStyle(d.tintColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !d.subtitle.isEmpty {
                        Text(d.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
