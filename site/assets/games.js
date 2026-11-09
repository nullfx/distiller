// The catalogue: the game list with search and filters, and a game's page (?game=<slug>).
import {
  coverPath, describeHardwareKey, describeRecipe, detailURL, facets, filterGames, genreName, graphicsName,
  installLink, mediaURL, officialInstaller, openLink, rankRecipes, safeHttpsURL, SLUG, sortGames,
} from "./catalogue-data.js";
import { el, fetchCatalogue, picture, recipeViewer, tierBadge } from "./site.js";

const root = document.getElementById("catalogue");
const params = new URLSearchParams(location.search);
const STORE_NAMES = { publisher: "Publisher's site", steam: "Steam", gog: "GOG", epic: "Epic Games Store", microsoft: "Microsoft Store", other: "Store" };

function showError(message) {
  root.replaceChildren(el("div", { class: "empty" },
    el("p", { text: message }),
    el("p", {}, el("a", { href: "./", text: "Back to all games" }))));
}

// MARK: The list

function renderList(index) {
  const games = index.games ?? [];
  const { genres, graphics } = facets(games);
  const state = {
    query: params.get("q") ?? "",
    genre: params.get("genre") ?? "",
    graphics: params.get("graphics") ?? "",
    minTier: params.get("tier") ?? "",
    sort: params.get("sort") ?? "title",
  };

  const search = el("input", { type: "search", placeholder: "Search games, publishers, descriptions", "aria-label": "Search games", value: state.query });
  const select = (label, key, options) => {
    const node = el("select", { "aria-label": label },
      options.map(([value, text]) => el("option", { value, text, selected: state[key] === value })));
    node.addEventListener("change", () => { state[key] = node.value; update(); });
    return node;
  };
  const genreSelect = select("Genre", "genre", [["", "All genres"], ...genres.map((genre) => [genre, genreName(genre)])]);
  const graphicsSelect = select("Graphics layer", "graphics", [["", "Any graphics layer"], ...graphics.map((layer) => [layer, graphicsName(layer)])]);
  const tierSelect = select("Rating", "minTier", [["", "Any rating"], ["platinum", "Platinum"], ["gold", "Gold or better"], ["silver", "Silver or better"], ["bronze", "Bronze or better"]]);
  const sortSelect = select("Sort", "sort", [["title", "Sort: title"], ["rating", "Sort: rating"], ["updated", "Sort: recently reported"]]);
  search.addEventListener("input", () => { state.query = search.value; update(); });

  const count = el("p", { class: "result-count", "aria-live": "polite" });
  const grid = el("div", { class: "game-grid" });
  root.replaceChildren(el("div", { class: "filters", role: "search" }, search, genreSelect, graphicsSelect, tierSelect, sortSelect), count, grid);

  function update() {
    const shown = sortGames(filterGames(games, state), state.sort);
    count.textContent = `${shown.length} of ${games.length} game${games.length === 1 ? "" : "s"}`;
    grid.replaceChildren(...(shown.length ? shown.map(card) : [el("div", { class: "empty", text: "No games match. Try fewer words or another filter." })]));
    const next = new URLSearchParams();
    if (state.query) next.set("q", state.query);
    if (state.genre) next.set("genre", state.genre);
    if (state.graphics) next.set("graphics", state.graphics);
    if (state.minTier) next.set("tier", state.minTier);
    if (state.sort !== "title") next.set("sort", state.sort);
    history.replaceState(null, "", next.size ? `?${next}` : location.pathname);
  }
  update();
}

function card(game) {
  const recipes = game.recipes?.length ?? 0;
  return el("a", { class: "game-card", href: `?game=${encodeURIComponent(game.slug)}` },
    picture(mediaURL(coverPath(game)), "", "cover") ?? el("div", { class: "cover", "aria-hidden": "true" }),
    el("div", { class: "body" },
      picture(mediaURL(game.icon), "", "icon") ?? el("div", { class: "icon", "aria-hidden": "true" }),
      el("h3", { text: game.title }),
      el("div", { class: "meta" },
        tierBadge(game.summary?.tier),
        el("span", { text: `${recipes} recipe${recipes === 1 ? "" : "s"}` }),
        (game.graphics ?? []).map((layer) => el("span", { class: "chip", text: graphicsName(layer) })))));
}

// MARK: A game

async function renderGame(slug) {
  const index = await fetchCatalogue("index.json");
  const game = (index.games ?? []).find((entry) => entry.slug === slug);
  if (!game || !detailURL(game)) return showError("The catalogue has no game by that name. It may not be published yet.");
  const detail = await fetchCatalogue(`games/${game.slug}.json`);
  document.title = `${game.title} · Distiller`;
  // The list's heading and intro don't belong on a game's page.
  document.querySelector(".page-head")?.setAttribute("hidden", "");

  const facts = [
    game.publisher && `Published by ${game.publisher}`,
    game.developer && game.developer !== game.publisher && `Developed by ${game.developer}`,
    game.release_year && String(game.release_year),
    (game.genres ?? []).map(genreName).join(", "),
  ].filter(Boolean);

  const recipes = rankRecipes(detail.recipes ?? []);
  const best = recipes[0];
  const screenshots = recipes.flatMap((recipe) => (recipe.screenshots ?? []).map((path) => ({ url: mediaURL(path), recipe }))).filter((shot) => shot.url);

  root.replaceChildren(
    el("a", { class: "back", href: "./", text: "← All games" }),
    el("header", { class: "game-head" },
      picture(mediaURL(game.icon), "", "icon") ?? el("div", { class: "icon", "aria-hidden": "true" }),
      el("div", {},
        el("h1", { text: game.title }),
        el("div", { class: "facts" }, facts.map((fact) => el("span", { text: fact })), tierBadge(game.summary?.tier, reportsSuffix(game.summary))))),
    el("div", { class: "game-layout" },
      el("div", {},
        screenshots.length ? gallery(screenshots) : null,
        game.description ? el("section", { class: "panel" }, el("h2", { text: "About the game" }), el("p", { class: "description", text: game.description })) : null,
        el("section", { class: "panel", id: "recipes" },
          el("h2", { text: `Recipes (${recipes.length})` }),
          recipes.map((recipe) => recipeBlock(game, recipe)))),
      el("aside", {},
        best ? installPanel(game, best) : null,
        linksPanel(game))));
}

function reportsSuffix(summary) {
  const count = summary?.reports ?? 0;
  return count ? ` · ${count} report${count === 1 ? "" : "s"}` : "";
}

function installPanel(game, recipe) {
  const link = installLink(game.slug, recipe.id);
  return el("section", { class: "panel" },
    el("h2", { text: "Play it on your Mac" }),
    el("p", { class: "muted", text: `Best rated: ${recipe.name ?? recipe.id} (${graphicsName(recipe.graphics)}).` }),
    el("div", { class: "button-row" },
      link ? el("a", { class: "button primary", href: link, text: "Install in Distiller" }) : null,
      openLink(game.slug) ? el("a", { class: "button", href: openLink(game.slug), text: "Open in Distiller" }) : null),
    el("p", { class: "install-help" },
      "Distiller asks before it installs anything, and installs the game from its publisher's official installer. ",
      el("a", { href: "../#get", text: "Don't have Distiller yet?" })));
}

function linksPanel(game) {
  const links = [];
  const website = safeHttpsURL(game.website);
  if (website) links.push(el("li", {}, el("a", { href: website, rel: "noopener", text: "Official website" })));
  for (const store of game.stores ?? []) {
    const url = safeHttpsURL(store.url);
    if (url) links.push(el("li", {}, el("a", { href: url, rel: "noopener", text: STORE_NAMES[store.name] ?? "Store" })));
  }
  const page = safeHttpsURL(officialInstaller(game)?.page);
  if (page) links.push(el("li", {}, el("a", { href: page, rel: "noopener", text: "Download page" }), el("span", { class: "muted", text: ` (${new URL(page).host})` })));
  const installer = safeHttpsURL(officialInstaller(game)?.url);
  if (installer) links.push(el("li", {}, el("a", { href: installer, rel: "noopener", text: "Official installer" }), el("span", { class: "muted", text: ` (${new URL(installer).host})` })));
  if (!links.length) return null;
  return el("section", { class: "panel" }, el("h2", { text: "Links" }), el("ul", { class: "link-list" }, links));
}

function gallery(shots) {
  let current = 0;
  const main = el("img", { alt: "", decoding: "async" });
  const mainButton = el("button", { class: "gallery-main", type: "button", "aria-label": "Show the screenshot larger" }, main);
  const lightboxImage = el("img", { alt: "" });
  const lightbox = el("dialog", { class: "lightbox", "aria-label": "Screenshot" },
    lightboxImage, el("form", { method: "dialog" }, el("button", { class: "button small", text: "Close" })));
  lightbox.addEventListener("click", (event) => { if (event.target === lightbox) lightbox.close(); });
  const thumbs = shots.map((shot, index) => el("button", {
    type: "button", "aria-label": `Screenshot ${index + 1}`, onclick: () => show(index),
  }, el("img", { src: shot.url, alt: "", loading: "lazy" })));
  function show(index) {
    current = index;
    main.src = shots[index].url;
    main.alt = `Screenshot ${index + 1} from the ${shots[index].recipe.name ?? shots[index].recipe.id} recipe's test run`;
    thumbs.forEach((thumb, i) => thumb.setAttribute("aria-pressed", String(i === index)));
  }
  mainButton.addEventListener("click", () => {
    lightboxImage.src = shots[current].url;
    lightboxImage.alt = main.alt;
    lightbox.showModal();
  });
  show(0);
  return el("section", { class: "panel" },
    el("h2", { class: "visually-hidden", text: "Screenshots" }),
    mainButton,
    shots.length > 1 ? el("div", { class: "thumbs" }, thumbs) : null,
    el("p", { class: "install-help", text: "Screenshots from community checks, where a contributor installed the game from its official installer and played it. Pictures belong to the game's publisher." }),
    lightbox);
}

function recipeBlock(game, recipe) {
  const link = installLink(game.slug, recipe.id);
  const viewer = recipeViewer(recipe.path, { title: "Recipe file", downloadName: `${game.slug}-${recipe.id}.yaml` });
  const details = describeRecipe(recipe.recipe);
  const authors = recipe.recipe?.authors ?? [];
  return el("article", { class: "recipe", id: `recipe-${recipe.id}` },
    el("div", { class: "recipe-head" },
      el("div", {},
        el("h3", { text: recipe.name && recipe.name !== game.title ? `${recipe.name} (${recipe.id})` : recipe.id }),
        el("div", { class: "facts" },
          tierBadge(recipe.summary?.tier, reportsSuffix(recipe.summary)),
          el("span", { class: "chip", text: graphicsName(recipe.graphics) }),
          authors.length ? el("span", { text: `by ${authors.join(", ")}` }) : null)),
      el("div", { class: "button-row" },
        link ? el("a", { class: "button small primary", href: link, text: "Install" }) : null,
        viewer ? el("button", {
          class: "button small", type: "button", text: "View recipe",
          onclick: () => { viewer.open = true; viewer.scrollIntoView({ behavior: "smooth", block: "start" }); },
        }) : null)),
    recipe.recipe?.notes ? el("p", { class: "description", text: recipe.recipe.notes }) : null,
    el("dl", { class: "details" }, details.flatMap(([term, value]) => [el("dt", { text: term }), el("dd", { text: value })])),
    viewer,
    hardwareTable(recipe),
    reportsList(recipe));
}

function hardwareTable(recipe) {
  const rows = Object.entries(recipe.by_hardware ?? {});
  if (!rows.length) return null;
  return el("div", {},
    el("h3", { text: "How it runs on different Macs" }),
    el("div", { class: "table-scroll" },
      el("table", {},
        el("thead", {}, el("tr", {}, el("th", { text: "Mac" }), el("th", { text: "Rating" }), el("th", { text: "Reports" }), el("th", { text: "Median FPS" }))),
        el("tbody", {}, rows.map(([key, summary]) => el("tr", {},
          el("td", { text: describeHardwareKey(key) }),
          el("td", {}, tierBadge(summary.tier)),
          el("td", { text: String(summary.reports ?? 0) }),
          el("td", { text: summary.median_fps ? String(Math.round(summary.median_fps)) : "—" })))))));
}

function reportsList(recipe) {
  const reports = recipe.reports ?? [];
  if (!reports.length) return el("p", { class: "muted", text: "No reports yet." });
  return el("div", {},
    el("h3", { text: "Reports" }),
    el("div", { class: "table-scroll" },
      el("table", {},
        el("thead", {}, el("tr", {}, el("th", { text: "Date" }), el("th", { text: "Mac" }), el("th", { text: "Rating" }), el("th", { text: "FPS" }), el("th", { text: "Notes" }))),
        el("tbody", {}, reports.slice(0, 50).map((report) => el("tr", {},
          el("td", { text: report.date ?? "" }),
          el("td", { text: describeHardwareKey(report.hardware_key) }),
          el("td", {}, tierBadge(report.tier)),
          el("td", { text: report.fps_avg ? String(Math.round(report.fps_avg)) : "—" }),
          el("td", { class: "report-notes", text: report.notes ?? "" })))))));
}

// MARK: Start

const slug = params.get("game");
const task = slug !== null
  ? (SLUG.test(slug) ? renderGame(slug) : Promise.resolve(showError("That isn't a game in the catalogue.")))
  : fetchCatalogue("index.json").then(renderList);
task.catch((error) => showError(`The catalogue couldn't be loaded. ${error.message ?? ""} Try again in a moment.`));
