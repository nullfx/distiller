import Foundation

public enum DistillerError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case invalidRecipe(String)
    case pathEscapesBottle(String)
    case insecureURL(String)
    case checksumMismatch(expected: String, actual: String)
    case winetricksVerbNotAllowed(String)
    case envKeyNotAllowed(String)
    case componentNotFound(String)
    case rosettaUnavailable(String)
    case bottleNotFound(String)
    case gameNotFound(String)
    case gptkLayoutNotRecognized(String)
    case missingUserFile(String)
    case processFailed(command: String, status: Int32, logFile: String?)
    case setupFailed(String)
    case wineBuildNotRecognized(String)
    case storageUnavailable(String)
    case storageNotUsable(String)
    case noFreeDriveLetter
    case graphicsNeedsOtherWine(String)
    case bottleNeedsItsWine(String)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable(let message):
            return message
        case .storageNotUsable(let detail):
            return detail
        case .graphicsNeedsOtherWine(let message), .bottleNeedsItsWine(let message):
            return message
        case .noFreeDriveLetter:
            return "Every drive letter from D: to Y: is already in use in this bottle."
        case .unsupportedSchema(let version):
            return "This recipe uses schema version \(version), but this version of Distiller reads version \(Recipe.supportedSchema). Update Distiller to use it."
        case .invalidRecipe(let detail):
            return "The recipe isn't valid: \(detail)"
        case .pathEscapesBottle(let path):
            return "The path \"\(path)\" points outside the bottle. Recipe paths must start with cache/, drive_c/ or C:\\."
        case .insecureURL(let url):
            return "The download \(url) doesn't use HTTPS. Recipes may only download over HTTPS."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded file's SHA-256 is \(actual), but the recipe expects \(expected). The file was not used."
        case .winetricksVerbNotAllowed(let verb):
            return "The winetricks verb \"\(verb)\" isn't on Distiller's allowlist."
        case .envKeyNotAllowed(let key):
            return "Recipes can't set the environment variable \(key)."
        case .componentNotFound(let what):
            return "No installed component provides \(what). Add one in Components."
        case .rosettaUnavailable(let component):
            return "\(component) needs Rosetta, which isn't available on this Mac. Install it with: softwareupdate --install-rosetta"
        case .bottleNotFound(let id):
            return "There's no bottle with the ID \(id)."
        case .gameNotFound(let id):
            return "There's no game in the library with the ID \(id)."
        case .gptkLayoutNotRecognized(let path):
            return "No D3DMetal files were found in \(path). Choose the Game Porting Toolkit disk image, its mounted volume, or a folder copied from it."
        case .missingUserFile(let prompt):
            return "The recipe needs a file you didn't provide: \(prompt)"
        case .setupFailed(let detail):
            return detail
        case .wineBuildNotRecognized(let path):
            return "No Wine build was found in \(path). Choose a folder or archive that contains bin/wine, such as \"Wine Staging.app\"."
        case .processFailed(let command, let status, let logFile):
            let log = logFile.map { " See the log at \($0)." } ?? ""
            return "\(command) exited with status \(status).\(log)"
        }
    }
}
