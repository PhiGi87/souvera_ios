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
    private var accountChangeObserver: NSObjectProtocol?
    /// Multi-Account-Generation: erhöht sich bei jedem Account-Wechsel.
    private var generation = 0
    /// Signaturen der Listen (Redundanz-Guard gegen identische Updates).
    private var spamSignature = ""
    private var fileSignature = ""
    private var virusSignature = ""

    /// Das persönliche Postfach des aktiven Kontos - nur dort darf man
    /// Whitelist-/Blacklist-Einträge hinzufügen.
    init() {
        // Multi-Account: beim Account-Wechsel die Quarantäne-/Listen-Zustände
        // auf den neuen Account umstellen (die API löst den Account pro
        // Request auf).
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(NCGlobal.shared.notificationCenterChangeUser),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetForAccountChange()
            }
        }
    }

    deinit {
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
        }
    }

    private func resetForAccountChange() {
        generation += 1
        spamSignature = ""
        fileSignature = ""
        virusSignature = ""
        spamQuarantine = .loading
        fileQuarantine = .loading
        virusQuarantine = .loading
        whitelist = .loading
        blacklist = .loading
        warnings = []
        mailboxes = []
        selectedMailbox = nil
        // CSRF-Token ist Account-/Session-gebunden: beim Wechsel verwerfen,
        // sonst schlägt der erste POST (Blacklist/Whitelist add/remove) des
        // neuen Accounts mit dem alten Token fehl.
        api.resetForAccountChange()
        Task { await self.loadAll() }
    }

    var personalMailbox: String? {
        NCManageDatabase.shared.getActiveTableAccount()?.user
    }

    /// Hinzufügen erlaubt, wenn das persönliche Postfach ausgewählt ist.
    var canAddEntry: Bool {
        guard let personalMailbox else { return false }
        return selectedMailbox == personalMailbox
    }

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
        let gen = generation
        warnings = []
        JmapLog.write("ShieldViewModel loadAll start (account=\(NCManageDatabase.shared.getActiveTableAccount()?.account ?? "-"))")

        var discovered: [String] = []
        if let result = await api.quarantineList(.spam) {
            guard gen == self.generation else { return }
            warnings += result.warnings
            let entries = result.data.compactMap { ShieldSpamEntry.from($0) }
            discovered += entries.compactMap(\.mailbox)
            let signature = entries.map { "\($0.id):\($0.seen)" }.joined(separator: ",")
            if signature != spamSignature {
                spamSignature = signature
                spamQuarantine = .success(entries)
            }
        } else {
            spamQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        if let result = await api.quarantineList(.file) {
            let entries = result.data.compactMap { ShieldGenericEntry.from($0) }
            discovered += entries.compactMap(\.mailbox)
            let signature = entries.map(\.id).joined(separator: ",")
            if signature != fileSignature {
                fileSignature = signature
                fileQuarantine = .success(entries)
            }
        } else {
            fileQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        if let result = await api.quarantineList(.virus) {
            let entries = result.data.compactMap { ShieldGenericEntry.from($0) }
            discovered += entries.compactMap(\.mailbox)
            let signature = entries.map(\.id).joined(separator: ",")
            if signature != virusSignature {
                virusSignature = signature
                virusQuarantine = .success(entries)
            }
        } else {
            virusQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        mailboxes = Array(Set(discovered)).sorted()
        // Das persönliche Postfach muss immer auswählbar sein - auch wenn es
        // gerade keine Quarantäne-Einträge hat (sonst verschwindet es aus der
        // Liste und das Hinzufügen von Whitelist/Blacklist wird unmöglich).
        if let personalMailbox, !mailboxes.contains(personalMailbox) {
            mailboxes.insert(personalMailbox, at: 0)
        }
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
