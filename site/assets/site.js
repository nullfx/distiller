// Shared page helpers. Catalogue data is written by the community: it only ever reaches the
// page through `el()` as text, and links only through the checks in catalogue-data.js.
import { CATALOGUE_BASE, highlightYAML, recipeRawURL, tierInfo } from "./catalogue-data.js";

/**
 * Creates an element. `props` sets attributes (`class`, `href`, `src`, …) and `text` sets
 * textContent; children are elements or strings (added as text, never parsed as HTML).
 */
export function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "text") node.textContent = String(value);
    else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of children.flat()) {
    if (child === undefined || child === null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

/** A tier badge ("● Gold"). */
export function tierBadge(tier, suffix = "") {
  const info = tierInfo(tier);
  return el("span", { class: `tier tier-${tier ?? "none"}`, title: info.summary, text: info.label + suffix });
}

/** Fetches a catalogue file (index.json, games/<slug>.json). */
export async function fetchCatalogue(path) {
  const response = await fetch(CATALOGUE_BASE + path, { cache: "no-cache" });
  if (!response.ok) throw new Error(`The catalogue answered ${response.status} for ${path}.`);
  return response.json();
}

/** An <img> that hides itself if the picture can't be loaded. */
export function picture(src, alt, className) {
  if (!src) return null;
  const image = el("img", { src, alt, class: className, loading: "lazy", decoding: "async" });
  image.addEventListener("error", () => { image.hidden = true; });
  return image;
}

/**
 * A recipe file shown on the page like a code block in a Markdown viewer: the file name,
 * Copy and Download, line numbers and YAML highlighting. Collapsed until opened; the file
 * is fetched the first time. `title` labels the toggle.
 */
export function recipeViewer(path, { title = "Recipe file", downloadName } = {}) {
  const url = recipeRawURL(path);
  if (!url) return null;
  const fileName = path.split("/").pop();
  const body = el("div", { class: "code-body" }, el("p", { class: "code-status", text: "Loading the recipe…" }));
  const copy = el("button", { class: "button small", type: "button", disabled: true, text: "Copy" });
  const download = el("a", { class: "button small", "aria-disabled": "true", text: "Download" });
  const block = el("div", { class: "code-block" },
    el("div", { class: "code-head" },
      el("span", { class: "code-name", text: path.replace(/^recipes\//, "") }),
      el("span", { class: "code-lang", text: "YAML" }),
      el("span", { class: "code-actions" }, copy, download)),
    body);
  const details = el("details", { class: "code-details" }, el("summary", { text: title }), block);
  let loaded = false;
  details.addEventListener("toggle", async () => {
    if (!details.open || loaded) return;
    loaded = true;
    try {
      const response = await fetch(url, { cache: "no-cache" });
      if (!response.ok) throw new Error(String(response.status));
      const text = await response.text();
      body.replaceChildren(codeLines(text));
      copy.disabled = false;
      copy.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(text);
          copy.textContent = "Copied";
        } catch {
          copy.textContent = "Couldn't copy";
        }
        setTimeout(() => { copy.textContent = "Copy"; }, 1600);
      });
      download.href = URL.createObjectURL(new Blob([text], { type: "application/yaml" }));
      download.setAttribute("download", downloadName ?? fileName);
      download.removeAttribute("aria-disabled");
    } catch {
      loaded = false;
      body.replaceChildren(el("p", { class: "code-status", text: "The recipe file couldn't be loaded. Close this and open it again to retry." }));
    }
  });
  return details;
}

/** Numbered, highlighted lines of YAML, every token as text. */
function codeLines(text) {
  const lines = highlightYAML(text.replace(/\n$/, ""));
  return el("pre", { class: "code", tabindex: "0" },
    el("code", {}, lines.map((tokens) => el("span", { class: "line" },
      tokens.map((token) => token.type === "plain" ? token.text : el("span", { class: `tok-${token.type}`, text: token.text }))))));
}

/** The year in the footer. */
for (const node of document.querySelectorAll("[data-year]")) node.textContent = String(new Date().getFullYear());
