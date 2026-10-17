"use strict";

const api = globalThis.browser ?? globalThis.chrome;

const queryInput = document.getElementById("query");
const resultsList = document.getElementById("results");
const header = document.getElementById("header");
const emptyState = document.getElementById("empty");

let allTabs = [];
let visible = [];
let selectedIndex = 0;

// ---- Matching -------------------------------------------------------------
//
// Mirrors Chrome's tab search (chrome/browser/resources/tab_group_shared/
// search.ts): exact, case- and accent-insensitive substring matching; every
// occurrence scores (DISTANCE - position) / DISTANCE * field weight; results
// are bucketed as match-at-start > match-at-word-start > other, then sorted by
// score. Unlike Chrome, each whitespace-separated word is matched on its own,
// so word order doesn't matter.

const FIELDS = [
  { key: "title", weight: 2 },
  { key: "displayUrl", weight: 1 },
];
const DISTANCE = 200;

// Lowercases and strips accents so "noticias" matches "Notícias". Also returns,
// for each folded character, the [start, length] of the original character it
// came from, so highlights land on the right characters.
function fold(text) {
  let str = "";
  const map = [];
  let i = 0;
  for (const ch of text) {
    const folded = ch.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
    for (let k = 0; k < folded.length; k++) map.push([i, ch.length]);
    str += folded;
    i += ch.length;
  }
  return { str, map };
}

function isWordStart(str, at) {
  return at === 0 || /[^\p{L}\p{N}]/u.test(str[at - 1]);
}

// Every term must occur in the title or hostname. Returns null otherwise.
function matchTab(tab, terms) {
  const hits = { title: new Set(), displayUrl: new Set() };
  let score = 0;
  let bucket = 0; // 0 = start of a field, 1 = start of a word, 2 = anywhere

  for (const term of terms) {
    let termBucket = 3; // no match yet
    for (const { key, weight } of FIELDS) {
      const { str, map } = tab.folded[key];
      for (let at = str.indexOf(term); at !== -1; at = str.indexOf(term, at + 1)) {
        score += Math.max((DISTANCE - at) / DISTANCE, 0) * weight;
        termBucket = Math.min(termBucket, at === 0 ? 0 : isWordStart(str, at) ? 1 : 2);
        for (let j = at; j < at + term.length; j++) {
          const [start, length] = map[j];
          for (let k = 0; k < length; k++) hits[key].add(start + k);
        }
      }
    }
    if (termBucket === 3) return null;
    // A tab ranks by its weakest word, so all words must line up to rank first.
    bucket = Math.max(bucket, termBucket);
  }
  return { score, bucket, titleHits: hits.title, urlHits: hits.displayUrl };
}

// ---- Rendering ------------------------------------------------------------

function originOf(url) {
  try {
    const u = new URL(url);
    if (u.protocol === "http:" || u.protocol === "https:") return u.origin;
  } catch {}
  return null;
}

function displayUrl(url) {
  try {
    const u = new URL(url);
    if (u.protocol === "http:" || u.protocol === "https:") {
      return u.hostname.replace(/^www\./, "");
    }
  } catch {}
  return url || "";
}

function letterColor(seed) {
  let hash = 0;
  for (const ch of seed) hash = (hash * 31 + ch.charCodeAt(0)) | 0;
  return `hsl(${Math.abs(hash) % 360} 55% 45%)`;
}

function letterIcon(tab) {
  const el = document.createElement("div");
  el.className = "favicon letter";
  const seed = tab.displayUrl || tab.title || "?";
  el.textContent = seed.charAt(0).toUpperCase();
  el.style.background = letterColor(seed);
  return el;
}

// Icon URLs to try, best first. Safari rarely fills in favIconUrl, so fall
// back to the icon the page declares (read by content.js), then the site's
// conventional /favicon.ico.
function faviconCandidates(tab) {
  const urls = [tab.favIconUrl, tab.pageIcon]
    .filter((url) => url && /^(https?|data):/.test(url));
  if (tab.origin) urls.push(`${tab.origin}/favicon.ico`);
  return [...new Set(urls)];
}

function iconImage(src) {
  const img = new Image();
  img.className = "favicon";
  img.alt = "";
  img.src = src;
  return img;
}

// Shows the letter tile right away and swaps in the first icon that loads,
// so rows never flash a broken image. Once an icon has loaded it's reused
// directly, so re-rendering while typing doesn't flicker.
function favicon(tab) {
  if (tab.iconSrc) return iconImage(tab.iconSrc);
  const placeholder = letterIcon(tab);
  const candidates = faviconCandidates(tab);

  const tryNext = () => {
    const src = candidates.shift();
    if (!src) return;
    const img = iconImage(src);
    img.addEventListener("load", () => {
      if (img.naturalWidth <= 1) return tryNext();
      tab.iconSrc = src;
      placeholder.replaceWith(img);
    }, { once: true });
    img.addEventListener("error", tryNext, { once: true });
  };

  tryNext();
  return placeholder;
}

// Builds a fragment for `text`, wrapping characters at `hits` in <mark>.
function highlighted(text, hits) {
  const frag = document.createDocumentFragment();
  if (!hits || hits.size === 0) {
    frag.append(text);
    return frag;
  }
  let run = "";
  let inMark = false;
  const flush = () => {
    if (!run) return;
    if (inMark) {
      const m = document.createElement("mark");
      m.textContent = run;
      frag.append(m);
    } else {
      frag.append(run);
    }
    run = "";
  };
  for (let i = 0; i < text.length; i++) {
    const hit = hits.has(i);
    if (hit !== inMark) {
      flush();
      inMark = hit;
    }
    run += text[i];
  }
  flush();
  return frag;
}

function renderRow(entry, index) {
  const { tab, match } = entry;
  const li = document.createElement("li");
  li.className = "tab";
  li.setAttribute("role", "option");
  li.dataset.index = index;
  li.dataset.tabId = tab.id;

  const text = document.createElement("div");
  text.className = "text";

  const title = document.createElement("div");
  title.className = "title";
  title.append(highlighted(tab.title, match?.titleHits));
  if (tab.active && tab.inCurrentWindow) {
    const dot = document.createElement("span");
    dot.className = "active-dot";
    dot.title = "Current tab";
    title.append(dot);
  }

  const url = document.createElement("div");
  url.className = "url";
  url.append(highlighted(tab.displayUrl, match?.urlHits));

  text.append(title, url);

  const close = document.createElement("button");
  close.className = "close";
  close.title = "Close tab";
  close.textContent = "×";
  close.addEventListener("click", (e) => {
    e.stopPropagation();
    closeTab(index);
  });

  li.append(favicon(tab), text, close);
  li.addEventListener("click", () => activate(index));
  li.addEventListener("mousemove", () => {
    if (selectedIndex !== index) select(index, false);
  });
  return li;
}

function render() {
  const terms = fold(queryInput.value).str.split(/\s+/).filter(Boolean);

  if (terms.length === 0) {
    visible = allTabs.map((tab) => ({ tab, match: null }));
  } else {
    visible = allTabs
      .map((tab, order) => ({ tab, order, match: matchTab(tab, terms) }))
      .filter((e) => e.match)
      .sort((a, b) =>
        (a.match.bucket - b.match.bucket) ||
        (b.match.score - a.match.score) ||
        (a.order - b.order));
  }

  resultsList.replaceChildren(...visible.map(renderRow));
  header.textContent = terms.length ? `Results (${visible.length})` : `Open tabs (${visible.length})`;
  emptyState.hidden = visible.length > 0;
  select(Math.min(selectedIndex, Math.max(visible.length - 1, 0)), true);
}

function select(index, scroll) {
  const rows = resultsList.children;
  rows[selectedIndex]?.classList.remove("selected");
  rows[selectedIndex]?.setAttribute("aria-selected", "false");
  selectedIndex = index;
  const row = rows[selectedIndex];
  if (!row) return;
  row.classList.add("selected");
  row.setAttribute("aria-selected", "true");
  if (scroll) row.scrollIntoView({ block: "nearest" });
}

// ---- Actions --------------------------------------------------------------

async function activate(index) {
  const entry = visible[index];
  if (!entry) return;
  const { id, windowId, inCurrentWindow } = entry.tab;
  // Close after a single round trip: the current window is already focused,
  // and focusing another window doesn't need to finish first.
  if (!inCurrentWindow) api.windows.update(windowId, { focused: true }).catch(() => {});
  await api.tabs.update(id, { active: true });
  window.close();
}

async function closeTab(index) {
  const entry = visible[index];
  if (!entry) return;
  allTabs = allTabs.filter((t) => t.id !== entry.tab.id);
  render();
  queryInput.focus();
  await api.tabs.remove(entry.tab.id);
}

// Safari's search field swallows Esc (it clears the text), so close the
// popup ourselves, like Chrome does.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  e.preventDefault();
  window.close();
}, { capture: true });

queryInput.addEventListener("input", () => {
  selectedIndex = 0;
  render();
});

queryInput.addEventListener("keydown", (e) => {
  const count = visible.length;
  const caretAtEnd = queryInput.selectionStart === queryInput.value.length;

  switch (e.key) {
    case "ArrowDown":
      if (count) select((selectedIndex + 1) % count, true);
      break;
    case "ArrowUp":
      if (count) select((selectedIndex - 1 + count) % count, true);
      break;
    case "Enter":
      activate(selectedIndex);
      break;
    case "Delete": // forward delete (fn+⌫) once there's nothing left to delete
      if (!caretAtEnd) return;
      closeTab(selectedIndex);
      break;
    case "Backspace": // ⌘⌫ with an empty query
      if (!e.metaKey || queryInput.value) return;
      closeTab(selectedIndex);
      break;
    default:
      return;
  }
  e.preventDefault();
});

// ---- Init -----------------------------------------------------------------

async function init() {
  // One parallel round trip: tabs, plus the icons content.js saved and the
  // last-activated times background.js records.
  const [tabs, current, stored] = await Promise.all([
    api.tabs.query({}),
    api.windows.getCurrent(),
    api.storage.local.get(["lastActive", "icons"]).catch(() => ({})),
  ]);
  const lastActive = stored.lastActive ?? {};
  const icons = stored.icons ?? {};

  allTabs = tabs.map((t) => {
    const title = t.title || t.url || "Untitled";
    const url = displayUrl(t.url);
    const origin = originOf(t.url);
    return {
      id: t.id,
      windowId: t.windowId,
      index: t.index,
      active: t.active,
      inCurrentWindow: t.windowId === current.id,
      lastActive: lastActive[t.id] ?? t.lastAccessed ?? 0,
      title,
      displayUrl: url,
      folded: { title: fold(title), displayUrl: fold(url) },
      origin,
      favIconUrl: t.favIconUrl,
      pageIcon: icons[origin] ?? null,
      iconSrc: null, // the icon that loaded, reused across re-renders
    };
  });

  // Like Chrome: most recently used first, with the tab you're already on at
  // the bottom (so the top row is the previous tab). Tabs with no recorded use
  // fall back to current window first, then tab-strip order.
  const isCurrentTab = (t) => t.active && t.inCurrentWindow;
  allTabs.sort((a, b) =>
    (isCurrentTab(a) - isCurrentTab(b)) ||
    (b.lastActive - a.lastActive) ||
    (b.inCurrentWindow - a.inCurrentWindow) ||
    (a.windowId - b.windowId) ||
    (a.index - b.index));

  render();
  queryInput.focus();
  // Wait until the list has painted before doing extra work.
  requestAnimationFrame(() => setTimeout(refreshPageIcons));
}

// Asks loaded tabs with no saved icon for the one they declare. Catches tabs
// opened before the extension was installed; content.js keeps the rest up to
// date as pages load. Unloaded tabs just fail and keep the fallback.
function refreshPageIcons() {
  for (const tab of allTabs) {
    if (!tab.origin || tab.favIconUrl || tab.pageIcon) continue;
    api.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] })
      .then((results) => {
        const href = results?.[0]?.result;
        if (!href) return;
        tab.pageIcon = href;
        tab.iconSrc = null;
        const icon = resultsList.querySelector(`[data-tab-id="${tab.id}"] .favicon`);
        icon?.replaceWith(favicon(tab));
      })
      .catch(() => {});
  }
}

init();
// Safari sometimes ignores autofocus in popups until after first paint.
setTimeout(() => queryInput.focus(), 50);
