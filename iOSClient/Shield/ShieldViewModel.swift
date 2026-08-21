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

    private let api = ShieldApi()

    struct ShieldFeedback: Equatable {
        let success: Bool
        let message: String
    }

    func loadAll() async {
        warnings = []

        if let result = await api.quarantineList(.spam) {
            warnings += result.warnings
            spamQuarantine = .success(result.data.compactMap { ShieldSpamEntry.from($0) })
        } else {
            spamQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        if let result = await api.quarantineList(.file) {
            fileQuarantine = .success(result.data.compactMap { ShieldGenericEntry.from($0) })
        } else {
            fileQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
        }
        if let result = await api.quarantineList(.virus) {
            virusQuarantine = .success(result.data.compactMap { ShieldGenericEntry.from($0) })
        } else {
            virusQuarantine = .error(NSLocalizedString("_shield_load_error_", comment: ""))
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
        await api.spamMessageDetail(id: id)
    }

    func release(_ kind: ShieldApi.QuarantineKind, ids: [String]) async {
        let ok = await api.release(kind, ids: ids)
        feedback = ShieldFeedback(
            success: ok,
            message: ok
                ? NSLocalizedString("_shield_released_", comment: "")
                : NSLocalizedString("_shield_action_failed_", comment: "")
        )
        if ok { await loadAll() }
    }

    func delete(_ kind: ShieldApi.QuarantineKind, ids: [String]) async {
        let ok = await api.delete(kind, ids: ids)
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
