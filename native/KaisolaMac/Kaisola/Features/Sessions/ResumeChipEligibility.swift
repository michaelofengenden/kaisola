import Foundation

/// Whether a resurrected terminal shows the one-keystroke agent resume chip.
/// Never for plain shells; never when the recorded account binding no longer
/// resolves (resuming under different credentials is the hazard the chip's
/// explicit click exists to prevent — a broken binding removes even that).
enum ResumeChipEligibility {
    static func shouldShow(agentID: String?, accountBindingResolves: Bool) -> Bool {
        guard let agentID, !agentID.isEmpty else { return false }
        return accountBindingResolves
    }
}
