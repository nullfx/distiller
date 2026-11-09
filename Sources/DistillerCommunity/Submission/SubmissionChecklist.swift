import Foundation
import DistillerCore

/// The steps of submitting a recipe, in the order the Submit window shows them.
public enum SubmissionStep: String, CaseIterable, Identifiable, Sendable {
    case details, installer, check, pictures, report, review

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .details: return "Details"
        case .installer: return "Installer"
        case .check: return "Community Check"
        case .pictures: return "Pictures"
        case .report: return "Report"
        case .review: return "Review & Submit"
        }
    }
}

/// Where one step stands.
public enum SubmissionStepStatus: Equatable, Sendable {
    /// Nothing more to do.
    case done
    /// Required before submitting.
    case needed
    /// It was done, but the recipe changed since: do it again.
    case outOfDate
    /// Recommended or optional, and not done. Doesn't block submitting.
    case optional

    public var blocksSubmitting: Bool { self == .needed || self == .outOfDate }
}

public struct SubmissionStepState: Equatable, Sendable, Identifiable {
    public var step: SubmissionStep
    public var status: SubmissionStepStatus
    /// One line for the sidebar, such as "Passed Nov 9" or "Add the official installer link".
    public var summary: String
    public var id: SubmissionStep { step }
}

/// What submitting a recipe needs, step by step, worked out from the game and the choices in
/// the Submit window. The window's sidebar shows it, and Submit is enabled only when no step
/// is needed or out of date.
public enum SubmissionChecklist {
    /// What the window knows besides the game.
    public struct Context: Sendable {
        /// Whether the catalogue already has this game. Nil until known (it needs a GitHub
        /// sign-in to look).
        public var isNewGame: Bool?
        /// The game's catalogue entry, needed when the game is new.
        public var details: GameDetails
        public var isSignedIn: Bool
        public var includesReport: Bool
        /// The player confirmed the recipe only downloads the official installer, and the licence.
        public var confirmed: Bool
        /// From `SubmissionPlan.issues`.
        public var issues: [SubmissionIssue]

        public init(isNewGame: Bool?, details: GameDetails, isSignedIn: Bool, includesReport: Bool, confirmed: Bool, issues: [SubmissionIssue]) {
            self.isNewGame = isNewGame
            self.details = details
            self.isSignedIn = isSignedIn
            self.includesReport = includesReport
            self.confirmed = confirmed
            self.issues = issues
        }
    }

    public static func make(for game: Game, context: Context) -> [SubmissionStepState] {
        SubmissionStep.allCases.map { step in
            let (status, summary) = state(of: step, game: game, context: context)
            return SubmissionStepState(step: step, status: status, summary: summary)
        }
    }

    /// True when nothing is needed or out of date.
    public static func isReady(_ states: [SubmissionStepState]) -> Bool {
        !states.contains { $0.status.blocksSubmitting }
    }

    static func state(of step: SubmissionStep, game: Game, context: Context) -> (SubmissionStepStatus, String) {
        let recipe = CommunityCheck.recipeToSubmit(for: game) ?? game.recipe
        switch step {
        case .details:
            if context.isNewGame == true, let problem = context.details.problems.first {
                return (.needed, problem)
            }
            if (recipe.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (.optional, "Add notes for other players")
            }
            return (.done, context.isNewGame == true ? "Catalogue entry and notes" : "Notes for other players")

        case .installer:
            guard let installer = game.recipe.game.installer else {
                return (.needed, "Add the official installer link")
            }
            return (.done, URL(string: installer.url)?.host ?? installer.url)

        case .check:
            guard game.recipe.game.installer != nil else { return (.needed, "Needs the installer link first") }
            guard let check = game.communityCheck else { return (.needed, "Not run yet") }
            guard CommunityCheck.isCurrent(game) else { return (.outOfDate, "The recipe changed since it passed") }
            return (.done, "Passed \(check.checkedAt.formatted(date: .abbreviated, time: .omitted))")

        case .pictures:
            guard CommunityCheck.isCurrent(game), let check = game.communityCheck else {
                return (.optional, "From the community check")
            }
            let shared = check.sharedCaptures?.count ?? 0
            let icon = check.hasIcon == true ? " and the icon" : ""
            if (check.captures ?? []).isEmpty { return (.optional, check.hasIcon == true ? "The icon only; no screenshots" : "No screenshots captured") }
            if shared == 0 { return (.optional, "None chosen to share") }
            return (.done, "\(shared) screenshot\(shared == 1 ? "" : "s")\(icon)")

        case .report:
            return context.includesReport ? (.done, "Included") : (.optional, "Not included")

        case .review:
            if !context.isSignedIn { return (.needed, "Sign in to GitHub") }
            // Errors the earlier steps don't cover: the recipe file itself, reserved slugs,
            // extra downloads, submitting not being set up.
            let covered = [SubmissionStep.installer, .check]
            let errors = context.issues.filter { $0.severity == .error }
            let uncovered = errors.filter { issue in !covered.contains { step in issueBelongs(issue, to: step) } }
            if let first = uncovered.first { return (.needed, first.message) }
            if !context.confirmed { return (.needed, "Confirm the installer and the licence") }
            return (.done, "Ready to submit")
        }
    }

    /// Issues `SubmissionPlan.issues` raises that a step already shows.
    static func issueBelongs(_ issue: SubmissionIssue, to step: SubmissionStep) -> Bool {
        switch step {
        case .installer: return issue.message.contains("official public installer")
        // The check chooses the program to launch, so a recipe without one needs the check.
        case .check: return issue.message.contains("community check") || issue.message.contains("program to launch")
        default: return false
        }
    }
}
