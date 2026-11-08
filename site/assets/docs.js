// Adds Copy buttons to the docs' code samples, and lists the catalogue's example recipes
// (examples.json) in the recipe format section.
import { graphicsName } from "./catalogue-data.js";
import { el, fetchCatalogue, recipeViewer } from "./site.js";

for (const pre of document.querySelectorAll("pre[data-copy]")) {
  const button = el("button", { class: "button small copy", type: "button", text: "Copy" });
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(pre.textContent);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Couldn't copy";
    }
    setTimeout(() => { button.textContent = "Copy"; }, 1600);
  });
  const wrap = el("div", { class: "copy-wrap" });
  pre.replaceWith(wrap);
  wrap.append(pre, button);
}

const examples = document.getElementById("examples");

fetchCatalogue("examples.json").then((index) => {
  const items = (index.games ?? []).flatMap((game) => (game.recipes ?? []).map((recipe) => ({ game, recipe })));
  if (!items.length) {
    examples.replaceChildren(el("p", { class: "muted", text: "No examples are published right now." }));
    return;
  }
  examples.replaceChildren(...items.map(({ game, recipe }) => recipeViewer(recipe.path, {
    title: `${game.title}: ${recipe.id} (${graphicsName(recipe.graphics)}${recipe.forked_from ? `, a fork of ${recipe.forked_from}` : ""})`,
    downloadName: `${game.slug}-${recipe.id}.yaml`,
  })).filter(Boolean));
}).catch(() => {
  examples.replaceChildren(el("p", {}, "See the ", el("a", { href: "https://github.com/nullfx/distiller-recipes/tree/main/recipes", text: "recipes folder" }), " in the repository."));
});
