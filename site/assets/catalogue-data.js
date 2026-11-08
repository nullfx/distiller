// The community catalogue's data, without any page code, so it can be tested with `node --test`.
//
// Everything here reads data the community writes (game descriptions, recipe names, report
// notes). Pages must only ever put it on screen as text (textContent), never as HTML, and only
// follow links this module has checked.

/** Where distiller-recipes publishes the catalogue (GitHub Pages). */
export const CATALOGUE_BASE = "https://nullfx.github.io/distiller-recipes/";
/** The recipes repository, for "view the recipe file" links. */
export const RECIPES_REPOSITORY = "https://github.com/nullfx/distiller-recipes";

/** Catalogue slugs and recipe ids, as the recipes repository's schemas define them. */
export const SLUG = /^[a-z0-9][a-z0-9-]{1,63}$/;

export const TIERS = {
  platinum: { label: "Platinum", rank: 4, summary: "Runs perfectly, no tweaks needed" },
  gold: { label: "Gold", rank: 3, summary: "Runs well after the recipe's tweaks" },
  silver: { label: "Silver", rank: 2, summary: "Runs with minor issues" },
  bronze: { label: "Bronze", rank: 1, summary: "Runs, but with significant issues" },
  borked: { label: "Borked", rank: 0, summary: "Doesn't run" },
};

const GRAPHICS = { d3dmetal: "D3DMetal", dxmt: "DXMT", dxvk: "DXVK", wined3d: "WineD3D" };
const GENRE_NAMES = { mmo: "MMO", rpg: "RPG" };
const WINE_FAMILIES = { winehq: "WineHQ", gptk: "Game Porting Toolkit", any: "Any Wine" };

export function tierInfo(tier) {
  return TIERS[tier] ?? { label: "Not rated", rank: -1, summary: "No reports yet" };
}

export function graphicsName(id) {
  return GRAPHICS[id] ?? String(id ?? "");
}

export function genreName(genre) {
  const text = String(genre ?? "");
  return GENRE_NAMES[text] ?? text.charAt(0).toUpperCase() + text.slice(1);
}

export function wineFamilyName(family) {
  // Families not listed here (such as a commercial Wine fork's source builds) are shown as-is.
  return WINE_FAMILIES[family] ?? String(family ?? "");
}

/**
 * A readable Mac description from a report's hardware key, such as
 * "M3-Pro-18gpu-36gb-macos27" → "M3 Pro · 18-core GPU · 36 GB · macOS 27".
 */
export function describeHardwareKey(key) {
  const match = /^(M\d+)-([A-Za-z]+)-(\d+)gpu-(\d+)gb-macos(\d+)$/.exec(String(key ?? ""));
  if (!match) return String(key ?? "");
  const [, family, tier, gpu, memory, macos] = match;
  const chip = tier === "Base" ? family : `${family} ${tier}`;
  return `${chip} · ${gpu}-core GPU · ${memory} GB · macOS ${macos}`;
}

/** The chip family of a hardware key ("M3"), for grouping. */
export function chipFamily(key) {
  return /^(M\d+)-/.exec(String(key ?? ""))?.[1] ?? null;
}

/** An https URL as a string, or null for anything else (javascript:, data:, http:, junk). */
export function safeHttpsURL(text) {
  try {
    const url = new URL(String(text));
    return url.protocol === "https:" ? url.href : null;
  } catch {
    return null;
  }
}

/** The published location of a catalogue picture ("media/…"), or null for anything else. */
export function mediaURL(path) {
  const text = String(path ?? "");
  if (!text.startsWith("media/") || text.split("/").some((part) => part === ".." || part === "")) return null;
  return CATALOGUE_BASE + text;
}

/** The detail file of a game ("games/<slug>.json"). */
export function detailURL(game) {
  return SLUG.test(game?.slug ?? "") ? `${CATALOGUE_BASE}games/${game.slug}.json` : null;
}

/** The recipe file in the repository, for "view the recipe" links. */
export function recipeSourceURL(path) {
  const text = String(path ?? "");
  if (!/^recipes\/[a-z0-9][a-z0-9-]{1,63}\/[a-z0-9][a-z0-9-]{1,63}\.yaml$/.test(text)) return null;
  return `${RECIPES_REPOSITORY}/blob/main/${text}`;
}

/** distiller://install?game=…&recipe=… (see DistillerLink.swift), or null for bad slugs. */
export function installLink(game, recipe) {
  if (!SLUG.test(game ?? "") || !SLUG.test(recipe ?? "")) return null;
  return `distiller://install?game=${game}&recipe=${recipe}`;
}

/** distiller://game/<slug>, or null for a bad slug. */
export function openLink(game) {
  return SLUG.test(game ?? "") ? `distiller://game/${game}` : null;
}

/** The best-rated recipe first; unrated recipes last. */
export function rankRecipes(recipes) {
  return [...(recipes ?? [])].sort((a, b) => {
    const tier = tierInfo(b.summary?.tier).rank - tierInfo(a.summary?.tier).rank;
    if (tier !== 0) return tier;
    return (b.summary?.reports ?? 0) - (a.summary?.reports ?? 0);
  });
}

/** The cover picture of a game: its best recipe's first screenshot. */
export function coverPath(game) {
  for (const recipe of rankRecipes(game?.recipes)) {
    if (recipe.screenshots?.length) return recipe.screenshots[0];
  }
  return null;
}

/** Every value of a field across the catalogue, for filter menus. */
export function facets(games) {
  const genres = new Set();
  const graphics = new Set();
  for (const game of games ?? []) {
    for (const genre of game.genres ?? []) genres.add(genre);
    for (const layer of game.graphics ?? []) graphics.add(layer);
  }
  return { genres: [...genres].sort(), graphics: [...graphics].sort() };
}

/**
 * Games matching the filters: `query` (title, publisher, developer, description),
 * `genre`, `graphics` (a layer any recipe uses) and `minTier` (a tier name).
 */
export function filterGames(games, { query = "", genre = "", graphics = "", minTier = "" } = {}) {
  const words = String(query).toLowerCase().split(/\s+/).filter(Boolean);
  const minimum = minTier ? tierInfo(minTier).rank : -Infinity;
  return (games ?? []).filter((game) => {
    const text = [game.title, game.publisher, game.developer, game.description].join(" ").toLowerCase();
    if (!words.every((word) => text.includes(word))) return false;
    if (genre && !(game.genres ?? []).includes(genre)) return false;
    if (graphics && !(game.graphics ?? []).includes(graphics)) return false;
    if (tierInfo(game.summary?.tier).rank < minimum) return false;
    return true;
  });
}

/** Sorts a copy: "title", "rating" (best first) or "updated" (newest report first). */
export function sortGames(games, by = "title") {
  const byTitle = (a, b) => String(a.title).localeCompare(String(b.title), undefined, { sensitivity: "base" });
  const copy = [...(games ?? [])];
  if (by === "rating") {
    return copy.sort((a, b) => tierInfo(b.summary?.tier).rank - tierInfo(a.summary?.tier).rank || byTitle(a, b));
  }
  if (by === "updated") {
    return copy.sort((a, b) => String(b.updated ?? "").localeCompare(String(a.updated ?? "")) || byTitle(a, b));
  }
  return copy.sort(byTitle);
}

/** A short, readable summary of what a recipe does, for its details list. */
export function describeRecipe(recipe) {
  const lines = [];
  const stack = recipe?.stack ?? {};
  if (stack.runner) {
    const version = stack.runner.min_version ? ` ${stack.runner.min_version} or later` : "";
    lines.push(["Wine", `${wineFamilyName(stack.runner.family)}${version}`]);
  }
  if (stack.graphics) lines.push(["Graphics", graphicsName(stack.graphics)]);
  if (stack.sync) lines.push(["Sync", String(stack.sync)]);
  const prefix = recipe?.prefix ?? {};
  if (prefix.windows) lines.push(["Windows version", String(prefix.windows).replace(/^win/, "Windows ")]);
  if (prefix.winetricks?.length) lines.push(["Winetricks", prefix.winetricks.join(", ")]);
  if (prefix.dll_overrides && Object.keys(prefix.dll_overrides).length) {
    lines.push(["DLL overrides", Object.entries(prefix.dll_overrides).map(([dll, mode]) => `${dll}=${mode}`).join(", ")]);
  }
  if (recipe?.env && Object.keys(recipe.env).length) {
    lines.push(["Environment", Object.entries(recipe.env).map(([key, value]) => `${key}=${value}`).join(", ")]);
  }
  if (recipe?.launch?.exe) lines.push(["Launches", String(recipe.launch.exe)]);
  if (recipe?.launch?.args?.length) lines.push(["Arguments", recipe.launch.args.join(" ")]);
  if (recipe?.overlays?.length) lines.push(["Hardware overlays", `${recipe.overlays.length} (settings that apply on particular Macs)`]);
  return lines;
}
