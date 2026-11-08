// Lists the catalogue's example recipes (examples.json) in the recipe format section.
import { graphicsName, recipeSourceURL } from "./catalogue-data.js";
import { el, fetchCatalogue } from "./site.js";

const examples = document.getElementById("examples");

fetchCatalogue("examples.json").then((index) => {
  const items = (index.games ?? []).flatMap((game) => (game.recipes ?? []).map((recipe) => ({ game, recipe })));
  if (!items.length) {
    examples.replaceChildren(el("p", { class: "muted", text: "No examples are published right now." }));
    return;
  }
  examples.replaceChildren(el("ul", {}, items.map(({ game, recipe }) => {
    const source = recipeSourceURL(recipe.path);
    return el("li", {},
      source ? el("a", { href: source, text: `${game.title}: ${recipe.id}` }) : `${game.title}: ${recipe.id}`,
      el("span", { class: "muted", text: ` (${graphicsName(recipe.graphics)}${recipe.forked_from ? `, a fork of ${recipe.forked_from}` : ""})` }));
  })));
}).catch(() => {
  examples.replaceChildren(el("p", {}, "See the ", el("a", { href: "https://github.com/nullfx/distiller-recipes/tree/main/recipes", text: "recipes folder" }), " in the repository."));
});
