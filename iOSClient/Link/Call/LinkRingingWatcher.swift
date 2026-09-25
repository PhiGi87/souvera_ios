// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.09. (Feedback: Klingel-UI blieb stehen, wenn der Call auf einem
// anderen Geraet angenommen wurde): Waehrend des Klingelns pollt der
// Watcher die Raum-Teilnehmer. Hat der EIGENE Actor (account.username ==
// actorId) inCall != 0, hat ein anderes Geraet des Nutzers angenommen
// (dieses Geraet hat beim Klingeln NICHT gejoint) - die Klingel-UI wird
// dann automatisch beendet.

import Foundation

@MainActor
final class LinkRingingWatcher {

    struct Decision: Equatable {
        let answeredElsewhere: Bool
    }

    private var pollTask: Task<Void, Never>?
    private var hasFired = false
    private let pollIntervalSeconds: UInt64 = 3

    /// Reine Entscheidungsfunktion (unit-testbar): true, wenn der eigene
    /// User von einem ANDEREN Geraet aus im Call ist.
    nonisolated static func evaluate(participants: [LinkParticipant], ownUserId: String) -> Decision {
        guard !ownUserId.isEmpty else { return Decision(answeredElsewhere: false) }
        let own = participants.filter {
            $0.actorType == "users" && $0.actorId == ownUserId
        }
        return Decision(answeredElsewhere: own.contains { $0.inCall != 0 })
    }

    /// Startet das Polling. `onAnsweredElsewhere` wird HOECHSTENS einmal
    /// gefeuert; der Watcher stoppt danach selbst.
    func start(account: LinkAccount, token: String,
               onAnsweredElsewhere: @escaping () -> Void) {
        stop()
        hasFired = false
        let api = LinkOcsApi(account: account)
        let ownUserId = account.username
        SouveraLog.write("RingingObs", "watching room=\(token) own=\(ownUserId)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let participants = await api.listParticipants(token: token)
                guard !Task.isCancelled, let self else { return }
                let decision = Self.evaluate(participants: participants, ownUserId: ownUserId)
                if decision.answeredElsewhere, !self.hasFired {
                    self.hasFired = true
                    SouveraLog.write("RingingObs", "answered elsewhere detected room=\(token)")
                    onAnsweredElsewhere()
                    self.stop()
                    return
                }
                try? await Task.sleep(nanoseconds: self.pollIntervalSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}
