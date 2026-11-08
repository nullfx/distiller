import Foundation

/// One step of a recipe's install section. Steps are data, not scripts: none of them
/// can run a command on the Mac itself. In YAML each step is a map with exactly one key:
///
///     - download: { url: https://…, sha256: …, to: cache/patch.zip }
///     - run_windows: { path: cache/setup.exe, args: ["/S"] }
///     - user_folder: { id: game-folder, prompt: "Choose the game's folder", to: 'C:\Games\Example' }
public enum InstallStep: Codable, Equatable, Sendable {
    case download(Download)
    case extract(Extract)
    case winetricks([String])
    case registry(RegistryEdit)
    case dllOverride([String: String])
    case copy(Copy)
    case runWindows(RunWindows)
    case userFile(UserFile)
    case userFolder(UserFolder)

    public struct Download: Codable, Equatable, Sendable {
        public var url: String
        public var sha256: String
        public var to: String
        public init(url: String, sha256: String, to: String) {
            self.url = url
            self.sha256 = sha256
            self.to = to
        }
    }

    public struct Extract: Codable, Equatable, Sendable {
        public var archive: String
        public var to: String
        public init(archive: String, to: String) {
            self.archive = archive
            self.to = to
        }
    }

    public struct Copy: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct RunWindows: Codable, Equatable, Sendable {
        public var path: String
        public var args: [String]?
        public var wait: Bool?
        public init(path: String, args: [String]? = nil, wait: Bool? = nil) {
            self.path = path
            self.args = args
            self.wait = wait
        }
    }

    /// Asks the player for a file they own, such as the game's installer.
    public struct UserFile: Codable, Equatable, Sendable {
        public var id: String
        public var prompt: String
        public var to: String
        public init(id: String, prompt: String, to: String) {
            self.id = id
            self.prompt = prompt
            self.to = to
        }
    }

    /// Asks the player for a folder they own, such as a game that is already installed
    /// somewhere on the Mac. The player can have it copied into the bottle (an APFS clone
    /// when it's on the same volume) or linked in place.
    public struct UserFolder: Codable, Equatable, Sendable {
        public var id: String
        public var prompt: String
        public var to: String
        public init(id: String, prompt: String, to: String) {
            self.id = id
            self.prompt = prompt
            self.to = to
        }
    }

    enum StepKey: String, CodingKey, CaseIterable {
        case download, extract, winetricks, registry, copy
        case dllOverride = "dll_override"
        case runWindows = "run_windows"
        case userFile = "user_file"
        case userFolder = "user_folder"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StepKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            let names = StepKey.allCases.map(\.rawValue).joined(separator: ", ")
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Each install step needs exactly one of these keys: \(names)."
            ))
        }
        switch key {
        case .download: self = .download(try container.decode(Download.self, forKey: key))
        case .extract: self = .extract(try container.decode(Extract.self, forKey: key))
        case .winetricks: self = .winetricks(try container.decode([String].self, forKey: key))
        case .registry: self = .registry(try container.decode(RegistryEdit.self, forKey: key))
        case .dllOverride: self = .dllOverride(try container.decode([String: String].self, forKey: key))
        case .copy: self = .copy(try container.decode(Copy.self, forKey: key))
        case .runWindows: self = .runWindows(try container.decode(RunWindows.self, forKey: key))
        case .userFile: self = .userFile(try container.decode(UserFile.self, forKey: key))
        case .userFolder: self = .userFolder(try container.decode(UserFolder.self, forKey: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StepKey.self)
        switch self {
        case .download(let value): try container.encode(value, forKey: .download)
        case .extract(let value): try container.encode(value, forKey: .extract)
        case .winetricks(let value): try container.encode(value, forKey: .winetricks)
        case .registry(let value): try container.encode(value, forKey: .registry)
        case .dllOverride(let value): try container.encode(value, forKey: .dllOverride)
        case .copy(let value): try container.encode(value, forKey: .copy)
        case .runWindows(let value): try container.encode(value, forKey: .runWindows)
        case .userFile(let value): try container.encode(value, forKey: .userFile)
        case .userFolder(let value): try container.encode(value, forKey: .userFolder)
        }
    }
}
