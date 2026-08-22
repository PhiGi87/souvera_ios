// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// View model for the Souvera Shield module: loads the three quarantines
// (spam/file/virus) and the whitelist/blacklist, and performs release,
// delete and list mutations.

import Combine
import Foundation

enum ShieldUiState<T> {
    case loading
    case success(T)
    case error(String)
}

@MainActor
final class ShieldViewModel: ObservableObject {
    @Published var spamQuarantine: ShieldUiState<[ShieldSpamEntry]> = .loading
    @Published var fileQuarantine: ShieldUiState<[ShieldGenericEntry]> = .loading
    @Published var virusQuarantine: ShieldUiState<[ShieldGenericEntry]> = .loading
    @Published var whitelist: ShieldUiState<[String]> = .loading
    @Published var blacklist: ShieldUiState<[String]> = .loading
    @Published var warnings: [String] = []
    @Published var feedback: ShieldFeedback?
    /// All mailboxes (pmails) discovered in the quarantine lists.
    @Published var mailboxes: [String] = []
    /// Selected mailbox filter; nil shows all mailboxes.
    @Published var selectedMailbox: String?

    private let api = ShieldApi()

    func filteredSpam() -> [ShieldSpamEntry] {
        guard case let .success(all) = spamQuarantine else { return [] }
        guard let selectedMailbox else { return all }
        return all.filter { $0.mailbox == selectedMailbox }
    }

    func filteredGeneric(_ state: ShieldUiState<[ShieldGenericEntry]>) -> [ShieldGenericEntry] {
        guard case let .success(all) = state else { return [] }
        guard let selectedMailbox else { return all }
        return all.filter { $0.mailbox == selectedMailbox }
    }

    struct ShieldFeedback: Equatable {
        let success: Bool
        let message: String
    }

    func loadAll() async {
        warnings = []

        var discovered: [String] = []
        if let result = await api.quarantineList(.spam) {
            warnings += result.warnings
            let entries = result.data.compactMap { ShieldSpamEntry.from($0) }
            discovered += entries.compactMap(\.mailbox)
            spamQuarantine = .success(entries)
        } else {
            spamQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        if let result = await api.quarantineList(.file) {
            let entries = result.data.compactMap { ShieldGenericEntry.from($0) }
            discovered += entries.compactMap(\.mailbox)
            fileQuarantine = .success(entries)
        } else {
            fileQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        if let result = await api.quarantineList(.virus) {
            let entries = result.data.compactMap { ShieldGenericEntry.from($0) }
            discovered += entries.compactMap(\.mailbox)
            virusQuarantine = .success(entries)
        } else {
            virusQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        mailboxes = Array(Set(discovered)).sorted()
        if let selected = selectedMailbox, !mailboxes.contains(selected) {
            selectedMailbox = nil
        }
        if let result = await api.list(.whitelist) {
            warnings += result.warnings
            whitelist = .success(result.data.compactMap { $0["value"] as? String })
        } else {
            whitelist = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        if let result = await api.list(.blacklist) {
            warnings += result.warnings
            blacklist = .success(result.data.compactMap { $0["value"] as? String })
        } else {
            blacklist = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
    }

    // MARK: - Quarantine actions

    func spamDetail(id: String) async -> [String: Any]? {
        await api.spamMessageDetail(id: id, email: selectedMailbox)
    }

    func release(_ kind: ShieldApi.QuarantineKind, ids: [String]) async {
        let ok = await api.release(kind, ids: ids, email: selectedMailbox)
        feedback = ShieldFeedback(
            success: ok,
            message: ok
                ? NSLocalizedString("_shield_released_", comment: "")
                : NSLocalizedString("_shield_action_failed_", comment: "")
        )
        if ok { await loadAll() }
    }

    /// Freigeben + Absender whitelisten (nur Spam-Quarantäne).
    func releaseWithWhitelist(ids: [String], entry: String) async {
        let address = Self.plainAddress(entry)
        guard !address.isEmpty else {
            feedback = ShieldFeedback(success: false, message: NSLocalizedString("_shield_action_failed_", comment: ""))
            return
        }
        let ok = await api.releaseWhitelist(ids: ids, email: selectedMailbox, entry: address)
        feedback = ShieldFeedback(
            success: ok,
            message: ok
                ? NSLocalizedString("_shield_released_whitelisted_", comment: "")
                : NSLocalizedString("_shield_action_failed_", comment: "")
        )
        if ok { await loadAll() }
    }

    /// Zieht aus "Name <mail@example.org>" die reine Adresse.
    static func plainAddress(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
            return String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    func delete(_ kind: ShieldApi.QuarantineKind, ids: [String]) async {
        let ok = await api.delete(kind, ids: ids, email: selectedMailbox)
        feedback = ShieldFeedback(
            success: ok,
            message: ok
                ? NSLocalizedString("_shield_deleted_", comment: "")
                : NSLocalizedString("_shield_action_failed_", comment: "")
        )
        if ok { await loadAll() }
    }

    // MARK: - List actions

    func addEntry(_ kind: ShieldApi.ListKind, entry: String) async {
        let ok = await api.add(kind, entry: entry)
        feedback = ShieldFeedback(
            success: ok,
            message: ok
                ? NSLocalizedString("_shield_added_", comment: "")
                : NSLocalizedString("_shield_action_failed_", comment: "")
        )
        if ok { await loadAll() }
    }

    func removeEntry(_ kind: ShieldApi.ListKind, entry: String) async {
        let ok = await api.remove(kind, entry: entry)
        feedback = ShieldFeedback(
            success: ok,
            message: ok
                ? NSLocalizedString("_shield_removed_", comment: "")
                : NSLocalizedString("_shield_action_failed_", comment: "")
        )
        if ok { await loadAll() }
    }
}
