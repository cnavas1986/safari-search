"use strict";

// Records when each tab was last activated, so the popup can list tabs most
// recently used first. Safari doesn't expose tab.lastAccessed to extensions.
// Stored as { lastActive: { [tabId]: timestamp } } in storage.local.

const api = globalThis.browser ?? globalThis.chrome;

// Serialize read-modify-write updates so rapid tab switches don't clobber
// each other.
let queue = Promise.resolve();

function update(change) {
  queue = queue
    .then(async () => {
      const { lastActive = {} } = await api.storage.local.get("lastActive");
      change(lastActive);
      await api.storage.local.set({ lastActive });
    })
    .catch(() => {});
  return queue;
}

function touch(tabId) {
  return update((lastActive) => { lastActive[tabId] = Date.now(); });
}

api.tabs.onActivated.addListener(({ tabId }) => touch(tabId));

// Switching windows activates that window's tab without a tab change event.
api.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId < 0) return; // WINDOW_ID_NONE: Safari lost focus
  const [tab] = await api.tabs.query({ active: true, windowId });
  if (tab) touch(tab.id);
});

api.tabs.onRemoved.addListener((tabId) =>
  update((lastActive) => { delete lastActive[tabId]; }));

// Icons used to be stored one key per site ("icon:<origin>"); move them into
// the single "icons" entry content.js now writes.
api.runtime.onInstalled.addListener(async () => {
  const all = await api.storage.local.get(null);
  const legacy = Object.keys(all).filter((k) => k.startsWith("icon:"));
  if (!legacy.length) return;
  const icons = all.icons ?? {};
  for (const key of legacy) icons[key.slice("icon:".length)] ??= all[key];
  await api.storage.local.set({ icons });
  await api.storage.local.remove(legacy);
});

// Tab IDs don't survive a browser restart; drop entries for tabs that are gone.
api.runtime.onStartup.addListener(async () => {
  const ids = new Set((await api.tabs.query({})).map((t) => String(t.id)));
  update((lastActive) => {
    for (const id of Object.keys(lastActive)) if (!ids.has(id)) delete lastActive[id];
  });
});
