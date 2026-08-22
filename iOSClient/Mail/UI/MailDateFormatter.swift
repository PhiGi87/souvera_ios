// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Central date formatting for the mail module: today shows only the time,
// yesterday shows "Yesterday" plus time, older messages show date and time.

import Foundation

enum MailDateFormatter {
    /// Compact label for message list rows.
    static func listLabel(for date: Date) -> String {
        let time = Self.time.string(from: date)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return time
        }
        if calendar.isDateInYesterday(date) {
            return "\(NSLocalizedString("_mail_yesterday_", comment: "")) \(time)"
        }
        return Self.full.string(from: date)
    }

    /// Full label for the message detail header.
    static func detailLabel(for date: Date) -> String {
        Self.full.string(from: date)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
