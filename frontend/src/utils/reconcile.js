// Structural sharing for data that is re-fetched in the background.
//
// Almost every page polls its data on an interval (useLiveRefresh), and the
// payload that comes back is usually identical to what's already on screen.
// Setting it straight into state hands React brand-new object identities
// every tick, which defeats memo() on every MediaCard / row in the list and
// re-renders (and re-diffs) the whole grid for nothing -- a visible hitch on
// long feeds, repeated every 20-30 seconds while the viewer is scrolling.
//
// These helpers keep the previous object whenever the new one is
// structurally equal, so an unchanged poll is a no-op render and a poll that
// changed one post only re-renders that one card.

// Structural equality over plain JSON-shaped values (string/number/boolean/
// null/array/plain object -- everything a parsed API response can contain).
// Not a JSON.stringify(a) === JSON.stringify(b) comparison: that's both
// slower (stringifies the whole payload just to throw the string away) and
// unreliable here, since nothing guarantees the backend's key order is
// stable across responses -- Lua's pairs()/cjson iteration order is
// unordered, so two logically-identical payloads could stringify with
// different key orders and wrongly register as "changed," defeating the
// whole point of this module.
export function sameJson(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (!a || !b || typeof a !== "object") return false;

  const aIsArray = Array.isArray(a);
  if (aIsArray !== Array.isArray(b)) return false;

  if (aIsArray) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!sameJson(a[i], b[i])) return false;
    }
    return true;
  }

  const aKeys = Object.keys(a);
  if (aKeys.length !== Object.keys(b).length) return false;
  for (const key of aKeys) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!sameJson(a[key], b[key])) return false;
  }
  return true;
}

// Returns `prev` itself when nothing changed, otherwise a new array that
// reuses every unchanged element (matched by `id`, falling back to index).
export function reconcileList(prev, next, key = "id") {
  if (!Array.isArray(next)) return prev;
  if (!Array.isArray(prev) || !prev.length) return next;
  const byKey = new Map();
  for (const row of prev) {
    const id = row && typeof row === "object" ? row[key] : undefined;
    if (id !== undefined && id !== null) byKey.set(String(id), row);
  }
  let changed = prev.length !== next.length;
  const out = next.map((row, index) => {
    const id = row && typeof row === "object" ? row[key] : undefined;
    const candidate = id !== undefined && id !== null ? byKey.get(String(id)) : prev[index];
    const kept = candidate !== undefined && sameJson(candidate, row) ? candidate : row;
    if (kept !== prev[index]) changed = true;
    return kept;
  });
  return changed ? out : prev;
}

// Same idea for a single object payload.
export function reconcileValue(prev, next) {
  return sameJson(prev, next) ? prev : next;
}
