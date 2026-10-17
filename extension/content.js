"use strict";

// Records the icon the page declares so the popup can show it. Also injected
// on demand by the popup, which reads the returned href (the script's value).
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const MAX_LENGTH = 8_000; // skip large inline data: icons
  const MAX_SITES = 500;

  // Rough size score: closest to 32px wins; SVG/"any" scale perfectly.
  function sizeScore(link) {
    const sizes = (link.getAttribute("sizes") || "").toLowerCase();
    if (sizes === "any" || /svg/.test(link.type) || /\.svg(\?|$)/i.test(link.href)) return 0;
    const px = sizes.split(/\s+/).map((s) => parseInt(s, 10)).filter((n) => n > 0);
    if (!px.length) return 16; // unspecified, usually a 16px .ico
    return Math.min(...px.map((n) => Math.abs(n - 32)));
  }

  function pageIcon() {
    const links = [...document.querySelectorAll("link[rel][href]")]
      .map((link) => ({ link, rel: link.rel.toLowerCase().split(/\s+/) }))
      .filter(({ rel }) => rel.includes("icon") || rel.includes("apple-touch-icon"))
      .filter(({ link }) => link.href.length <= MAX_LENGTH);
    if (!links.length) return null;

    // Prefer regular icons over touch icons, then the best size.
    links.sort((a, b) =>
      (b.rel.includes("icon") - a.rel.includes("icon")) ||
      (sizeScore(a.link) - sizeScore(b.link)));
    return links[0].link.href;
  }

  // All sites share one { icons: { [origin]: href } } entry so the popup can
  // read it in the same round trip as everything else. Capped to the most
  // recently saved sites to keep that read small.
  const href = pageIcon();
  if (href) {
    api.storage.local.get("icons").then(({ icons = {} }) => {
      if (icons[location.origin] === href) return;
      delete icons[location.origin]; // re-insert as newest
      icons[location.origin] = href;
      const origins = Object.keys(icons);
      for (const o of origins.slice(0, origins.length - MAX_SITES)) delete icons[o];
      return api.storage.local.set({ icons });
    }).catch(() => {});
  }
  return href;
})();
