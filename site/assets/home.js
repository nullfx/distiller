// The home page's "Popular in the catalogue" cards.
import { coverPath, graphicsName, mediaURL, sortGames } from "./catalogue-data.js";
import { el, fetchCatalogue, picture, tierBadge } from "./site.js";

const featured = document.getElementById("featured");

fetchCatalogue("index.json").then((index) => {
  const games = sortGames(index.games ?? [], "rating").slice(0, 6);
  if (!games.length) {
    featured.replaceChildren(el("div", { class: "empty", text: "The catalogue is empty so far. Be the first to share a recipe." }));
    return;
  }
  featured.replaceChildren(...games.map((game) =>
    el("a", { class: "game-card", href: `games/?game=${encodeURIComponent(game.slug)}` },
      picture(mediaURL(coverPath(game)), "", "cover") ?? el("div", { class: "cover", "aria-hidden": "true" }),
      el("div", { class: "body" },
        picture(mediaURL(game.icon), "", "icon") ?? el("div", { class: "icon", "aria-hidden": "true" }),
        el("h3", { text: game.title }),
        el("div", { class: "meta" }, tierBadge(game.summary?.tier), (game.graphics ?? []).map((layer) => el("span", { class: "chip", text: graphicsName(layer) })))))));
}).catch(() => {
  featured.replaceChildren(el("div", { class: "empty" }, "The catalogue couldn't be loaded right now. ", el("a", { href: "games/", text: "Try the games page" })));
});
