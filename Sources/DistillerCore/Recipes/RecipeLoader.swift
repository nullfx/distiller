import Foundation
import Yams

public enum RecipeLoader {
    public static func load(from url: URL) throws -> Recipe {
        try decode(yaml: String(contentsOf: url, encoding: .utf8))
    }

    public static func decode(yaml: String) throws -> Recipe {
        let recipe: Recipe
        do {
            recipe = try YAMLDecoder().decode(Recipe.self, from: yaml)
        } catch let error as DecodingError {
            throw DistillerError.invalidRecipe(describe(error))
        }
        try validate(recipe)
        return recipe
    }

    public static func encode(_ recipe: Recipe) throws -> String {
        try YAMLEncoder().encode(recipe)
    }

    /// The safety and consistency checks Distiller applies before trusting a recipe.
    public static func validate(_ recipe: Recipe) throws {
        guard recipe.schema == Recipe.supportedSchema else {
            throw DistillerError.unsupportedSchema(recipe.schema)
        }
        guard RecipePolicy.isValidSlug(recipe.id) else {
            throw DistillerError.invalidRecipe("id \"\(recipe.id)\" must be 2–64 lowercase letters, digits or hyphens.")
        }
        guard RecipePolicy.isValidSlug(recipe.game.slug) else {
            throw DistillerError.invalidRecipe("game.slug \"\(recipe.game.slug)\" must be 2–64 lowercase letters, digits or hyphens.")
        }

        if let installer = recipe.game.installer {
            guard let url = URL(string: installer.url), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
                throw DistillerError.invalidRecipe("game.installer.url must be an https:// link to the publisher's installer.")
            }
        }
        try RecipePolicy.checkVerbs(recipe.prefix?.winetricks ?? [])
        try RecipePolicy.checkEnv(recipe.env)
        try RecipePolicy.checkDLLOverrides(recipe.prefix?.dllOverrides)
        try RecipePolicy.checkRegistry(recipe.prefix?.registry)

        // Paths are checked against a throwaway root; only their shape matters here.
        let scratch = URL(fileURLWithPath: "/distiller-validate/bottle", isDirectory: true)
        for step in recipe.install ?? [] {
            switch step {
            case .download(let download):
                guard let url = URL(string: download.url), url.scheme?.lowercased() == "https" else {
                    throw DistillerError.insecureURL(download.url)
                }
                guard download.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
                    throw DistillerError.invalidRecipe("The download \(download.url) needs a 64-character sha256.")
                }
                _ = try BottlePath.resolve(download.to, in: scratch)
            case .extract(let extract):
                _ = try BottlePath.resolve(extract.archive, in: scratch)
                _ = try BottlePath.resolve(extract.to, in: scratch)
            case .winetricks(let verbs):
                try RecipePolicy.checkVerbs(verbs)
            case .registry(let edit):
                try RecipePolicy.checkRegistry([edit])
            case .dllOverride(let overrides):
                try RecipePolicy.checkDLLOverrides(overrides)
            case .copy(let copy):
                _ = try BottlePath.resolve(copy.from, in: scratch)
                _ = try BottlePath.resolve(copy.to, in: scratch)
            case .runWindows(let run):
                _ = try BottlePath.resolve(run.path, in: scratch)
            case .userFile(let file):
                guard RecipePolicy.isValidSlug(file.id) else {
                    throw DistillerError.invalidRecipe("user_file id \"\(file.id)\" must be lowercase letters, digits or hyphens.")
                }
                _ = try BottlePath.resolve(file.to, in: scratch)
            case .userFolder(let folder):
                guard RecipePolicy.isValidSlug(folder.id) else {
                    throw DistillerError.invalidRecipe("user_folder id \"\(folder.id)\" must be lowercase letters, digits or hyphens.")
                }
                guard BottlePath.isInsideDriveC(folder.to) else {
                    throw DistillerError.invalidRecipe("user_folder must go somewhere on drive C:, such as C:\\Games\\<name>, so Windows programs can see it.")
                }
                _ = try BottlePath.resolve(folder.to, in: scratch)
            }
        }

        if let launch = recipe.launch {
            _ = try BottlePath.resolve(launch.exe, in: scratch)
            if let workingDir = launch.workingDir {
                _ = try BottlePath.resolve(workingDir, in: scratch)
            }
        }

        for overlay in recipe.overlays ?? [] {
            try RecipePolicy.checkEnv(overlay.env)
            try RecipePolicy.checkDLLOverrides(overlay.dllOverrides)
            try RecipePolicy.checkRegistry(overlay.registry)
            try RecipePolicy.checkVerbs((overlay.winetricks ?? []) + (overlay.appendWinetricks ?? []))
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "(top level)" : joined
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context)): missing \"\(key.stringValue)\"."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
