// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Darwin

/// P68y: Zählt die offenen Datei-Deskriptoren des Prozesses, um das
/// FD-Leck (Termination 0xdead10cc) nachweisbar zu machen bzw. zu finden.
/// Implementiert ohne private API: iteriert 0..<getdtablesize() und prüft
/// jeden FD mit fcntl(F_GETFD).
enum SouveraFdDiagnostics {

    static func openFileDescriptorCount() -> Int {
        let max = Int(getdtablesize())
        var count = 0
        for fd in 0..<max {
            if fcntl(Int32(fd), F_GETFD) >= 0 {
                count += 1
            }
        }
        return count
    }

    /// Startet die periodische Diagnose (alle 60 s ein Log-Eintrag).
    static func startPeriodicLogging() {
        schedule()
    }

    private static func schedule() {
        SouveraLog.write("FdDiag", "open fds = \(openFileDescriptorCount())")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            schedule()
        }
    }
}
