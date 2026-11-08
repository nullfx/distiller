import Foundation

/// The safety rules shared recipes must follow. Keep these lists in sync with
/// `schema/recipe.schema.json` in the distiller-recipes repository.
public enum RecipePolicy {
    /// Winetricks verbs a recipe may install. Anything else is rejected at load time.
    public static let winetricksVerbs: Set<String> = [
        "vcrun2005", "vcrun2008", "vcrun2010", "vcrun2012", "vcrun2013",
        "vcrun2015", "vcrun2017", "vcrun2019", "vcrun2022",
        "d3dcompiler_43", "d3dcompiler_46", "d3dcompiler_47",
        "d3dx9", "d3dx10", "d3dx11_42", "d3dx11_43",
        "dotnet40", "dotnet45", "dotnet472", "dotnet48",
        "dotnetdesktop6", "dotnetdesktop8",
        "xact", "xact_x64", "xinput", "physx", "faudio", "openal",
        "corefonts", "tahoma", "mfc42", "mfc140",
        "msxml3", "msxml6", "quartz", "devenum",
    ]

    /// Environment variables are allowed only with these prefixes…
    public static let envAllowedPrefixes = ["WINE", "DXVK_", "DXMT_", "MTL_", "D3DM_", "MVK_", "VKD3D_"]

    /// …and never these, because they could redirect Wine or load code on the Mac itself.
    /// (`DYLD_*`, `PATH` and `HOME` are already excluded by the prefix rule.)
    public static let envDenied: Set<String> = [
        "WINE", "WINEPREFIX", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEARCH", "WINEDLLOVERRIDES",
    ]

    public static let dllOverrideValues: Set<String> = [
        "native", "builtin", "native,builtin", "builtin,native", "n", "b", "n,b", "b,n", "disabled", "",
    ]

    public static let registryHives = ["HKCU\\", "HKLM\\", "HKEY_CURRENT_USER\\", "HKEY_LOCAL_MACHINE\\"]

    public static func isAllowedEnvKey(_ key: String) -> Bool {
        guard key.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else { return false }
        guard !envDenied.contains(key) else { return false }
        return envAllowedPrefixes.contains { key.hasPrefix($0) }
    }

    public static func isValidSlug(_ slug: String) -> Bool {
        slug.range(of: "^[a-z0-9][a-z0-9-]{1,63}$", options: .regularExpression) != nil
    }

    public static func isValidDLLName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }

    public static func checkVerbs(_ verbs: [String]) throws {
        for verb in verbs where !winetricksVerbs.contains(verb) {
            throw DistillerError.winetricksVerbNotAllowed(verb)
        }
    }

    public static func checkEnv(_ env: [String: String]?) throws {
        for key in (env ?? [:]).keys where !isAllowedEnvKey(key) {
            throw DistillerError.envKeyNotAllowed(key)
        }
    }

    public static func checkDLLOverrides(_ overrides: [String: String]?) throws {
        for (name, value) in overrides ?? [:] {
            guard isValidDLLName(name) else {
                throw DistillerError.invalidRecipe("\"\(name)\" isn't a valid DLL name.")
            }
            guard dllOverrideValues.contains(value.lowercased()) else {
                throw DistillerError.invalidRecipe("\"\(value)\" isn't a valid DLL override for \(name). Use native, builtin, native,builtin, builtin,native or disabled.")
            }
        }
    }

    public static func checkRegistry(_ edits: [RegistryEdit]?) throws {
        for edit in edits ?? [] {
            guard registryHives.contains(where: { edit.key.uppercased().hasPrefix($0.uppercased()) }) else {
                throw DistillerError.invalidRecipe("The registry key \"\(edit.key)\" must start with HKCU\\ or HKLM\\.")
            }
        }
    }
}
