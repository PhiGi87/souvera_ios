// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
enum MailUiState<T> { case loading; case success(T); case error(String) }
enum MailRoute: Equatable {
    case folders
    static func == (lhs: MailRoute, rhs: MailRoute) -> Bool { true }
}
@MainActor final class MailViewModel: ObservableObject {
    @Published var route: MailRoute = .folders
    func start() {}
    func back() {}
}
