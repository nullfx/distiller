// Run with: node --test site/tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CATALOGUE_BASE, chipFamily, coverPath, describeHardwareKey, describeRecipe, facets, filterGames,
  highlightYAML, installLink, mediaURL, officialInstaller, openLink, rankRecipes, recipeRawURL, recipeSourceURL, safeHttpsURL, sortGames, tierInfo,
} from "../assets/catalogue-data.js";

const games = [
  {
    slug: "guild-wars-2", title: "Guild Wars 2", publisher: "ArenaNet", genres: ["mmo", "rpg"],
    graphics: ["dxvk"], summary: { tier: "gold", reports: 1 }, updated: "2026-11-07",
    recipes: [
      { id: "dxvk", summary: { tier: "gold", reports: 1 }, screenshots: ["media/guild-wars-2/dxvk/1.jpg"] },
      { id: "wined3d", summary: { tier: null, reports: 0 } },
    ],
  },
  { slug: "another-game", title: "another Game", genres: ["puzzle"], graphics: ["d3dmetal"], summary: { tier: "platinum", reports: 3 }, updated: "2026-10-01", recipes: [] },
  { slug: "old-game", title: "Zebra Quest", description: "A quest with zebras.", genres: ["rpg"], graphics: ["wined3d"], summary: { tier: null, reports: 0 }, recipes: [] },
];

test("links to Distiller only for valid slugs", () => {
  assert.equal(installLink("guild-wars-2", "dxvk"), "distiller://install?game=guild-wars-2&recipe=dxvk");
  assert.equal(installLink("Guild Wars", "dxvk"), null);
  assert.equal(installLink("guild-wars-2", "x&game=evil"), null);
  assert.equal(openLink("guild-wars-2"), "distiller://game/guild-wars-2");
  assert.equal(openLink("../x"), null);
});

test("only https links and catalogue pictures are followed", () => {
  assert.equal(safeHttpsURL("https://www.guildwars2.com/"), "https://www.guildwars2.com/");
  assert.equal(safeHttpsURL("javascript:alert(1)"), null);
  assert.equal(safeHttpsURL("http://example.com"), null);
  assert.equal(safeHttpsURL("data:text/html,hi"), null);
  assert.equal(mediaURL("media/guild-wars-2/icon.png"), CATALOGUE_BASE + "media/guild-wars-2/icon.png");
  assert.equal(mediaURL("media/../index.json"), null);
  assert.equal(mediaURL("https://evil.example/x.png"), null);
  assert.equal(mediaURL(undefined), null);
  assert.equal(recipeSourceURL("recipes/guild-wars-2/dxvk.yaml"), "https://github.com/nullfx/distiller-recipes/blob/main/recipes/guild-wars-2/dxvk.yaml");
  assert.equal(recipeSourceURL("scripts/build_index.py"), null);
});

test("describes Macs from report hardware keys", () => {
  assert.equal(describeHardwareKey("M3-Pro-18gpu-36gb-macos27"), "M3 Pro · 18-core GPU · 36 GB · macOS 27");
  assert.equal(describeHardwareKey("M1-Base-8gpu-8gb-macos26"), "M1 · 8-core GPU · 8 GB · macOS 26");
  assert.equal(describeHardwareKey("something-else"), "something-else");
  assert.equal(chipFamily("M4-Max-40gpu-64gb-macos27"), "M4");
});

test("filters by text, genre, graphics layer and rating", () => {
  const titles = (list) => list.map((game) => game.title);
  assert.deepEqual(titles(filterGames(games, { query: "guild" })), ["Guild Wars 2"]);
  assert.deepEqual(titles(filterGames(games, { query: "zebras" })), ["Zebra Quest"], "descriptions are searched");
  assert.deepEqual(titles(filterGames(games, { query: "arena guild" })), ["Guild Wars 2"], "every word must match");
  assert.deepEqual(titles(filterGames(games, { genre: "rpg" })), ["Guild Wars 2", "Zebra Quest"]);
  assert.deepEqual(titles(filterGames(games, { graphics: "d3dmetal" })), ["another Game"]);
  assert.deepEqual(titles(filterGames(games, { minTier: "gold" })), ["Guild Wars 2", "another Game"]);
  assert.deepEqual(facets(games), { genres: ["mmo", "puzzle", "rpg"], graphics: ["d3dmetal", "dxvk", "wined3d"] });
});

test("sorts by title, rating and newest report", () => {
  const titles = (list) => list.map((game) => game.title);
  assert.deepEqual(titles(sortGames(games, "title")), ["another Game", "Guild Wars 2", "Zebra Quest"]);
  assert.deepEqual(titles(sortGames(games, "rating")), ["another Game", "Guild Wars 2", "Zebra Quest"]);
  assert.deepEqual(titles(sortGames(games, "updated")), ["Guild Wars 2", "another Game", "Zebra Quest"]);
});

test("ranks recipes and picks a cover", () => {
  assert.deepEqual(rankRecipes(games[0].recipes).map((recipe) => recipe.id), ["dxvk", "wined3d"]);
  assert.equal(coverPath(games[0]), "media/guild-wars-2/dxvk/1.jpg");
  assert.equal(coverPath(games[1]), null);
  assert.equal(tierInfo("gold").label, "Gold");
  assert.equal(tierInfo(null).label, "Not rated");
});

test("summarises a recipe", () => {
  const lines = Object.fromEntries(describeRecipe({
    stack: { runner: { family: "winehq", min_version: "11.0" }, graphics: "dxvk", sync: "msync" },
    prefix: { windows: "win11", winetricks: ["corefonts"] },
    env: { DXVK_ASYNC: "1" },
    launch: { exe: "C:\\Program Files\\Guild Wars 2\\Gw2-64.exe", args: ["-mapLoadinfo"] },
  }));
  assert.equal(lines.Wine, "WineHQ 11.0 or later");
  assert.equal(lines.Graphics, "DXVK");
  assert.equal(lines["Windows version"], "Windows 11");
  assert.equal(lines.Environment, "DXVK_ASYNC=1");
  assert.equal(lines.Arguments, "-mapLoadinfo");
});

test("recipe files are fetched only from the recipes folder", () => {
  assert.equal(recipeRawURL("recipes/guild-wars-2/dxvk.yaml"), "https://raw.githubusercontent.com/nullfx/distiller-recipes/main/recipes/guild-wars-2/dxvk.yaml");
  assert.equal(recipeRawURL("recipes/../scripts/x.yaml"), null);
  assert.equal(recipeRawURL("https://evil.example/x.yaml"), null);
});

test("highlights YAML without changing it", () => {
  const source = [
    "# A comment",
    "schema: 1",
    "id: dxvk",
    "game:",
    "  title: Guild Wars 2  # trailing comment",
    "  installer: { url: \"https://cdn.example.com/Setup.exe\" }",
    "prefix:",
    "  winetricks: [corefonts, vcrun2022]",
    "  retina: true",
    "install:",
    "  - download: { url: https://cdn.example.com/a.exe, sha256: \"ab\", to: cache/a.exe }",
    "launch:",
    "  exe: 'C:\\Program Files\\Game\\Game.exe'",
    "  args: [\"-a\", '-b']",
    "notes: |",
    "  Text with: a colon and # not a comment",
    "",
    "  - <script>alert(1)</script>",
  ].join("\n");
  const lines = highlightYAML(source);
  assert.equal(lines.map((tokens) => tokens.map((token) => token.text).join("")).join("\n"), source, "round trip");
  const types = (n) => lines[n].filter((token) => token.text.trim()).map((token) => `${token.type}:${token.text.trim()}`);
  assert.deepEqual(types(0), ["comment:# A comment"]);
  assert.deepEqual(types(1), ["key:schema", "punct::", "number:1"]);
  assert.deepEqual(types(4), ["key:title", "punct::", "string:Guild Wars 2", "comment:# trailing comment"]);
  assert.deepEqual(types(5), ["key:installer", "punct::", "punct:{", "key:url", "punct::", "string:\"https://cdn.example.com/Setup.exe\"", "punct:}"]);
  assert.deepEqual(types(7), ["key:winetricks", "punct::", "punct:[", "string:corefonts", "punct:,", "string:vcrun2022", "punct:]"]);
  assert.deepEqual(types(8), ["key:retina", "punct::", "literal:true"]);
  assert.equal(types(10)[0], "punct:-");
  assert.deepEqual(types(12), ["key:exe", "punct::", "string:'C:\\Program Files\\Game\\Game.exe'"]);
  assert.deepEqual(types(14), ["key:notes", "punct::", "punct:|"]);
  assert.deepEqual(types(15), ["string:Text with: a colon and # not a comment"], "a block scalar's lines are text");
  assert.ok(types(17).join(" ").includes("<script>"), "markup stays text for the page to show as text");
});

test("officialInstaller reads a link or, published separately, only a download page", () => {
  const direct = { url: "https://cdn.example.com/Setup.exe", page: "https://www.example.com/download" };
  assert.deepEqual(officialInstaller({ installer: direct }), direct);
  assert.deepEqual(officialInstaller({ download_page: "https://www.example.com/download", download_page_updates: true }),
    { page: "https://www.example.com/download", updates: true });
  assert.equal(officialInstaller({}), null);
});
