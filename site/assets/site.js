// Shared page helpers. Catalogue data is written by the community: it only ever reaches the
// page through `el()` as text, and links only through the checks in catalogue-data.js.
import { CATALOGUE_BASE, tierInfo } from "./catalogue-data.js";

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

/** The year in the footer. */
for (const node of document.querySelectorAll("[data-year]")) node.textContent = String(new Date().getFullYear());
