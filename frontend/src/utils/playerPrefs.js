// Per-viewer, per-browser playback preferences and resume positions.
//
// Everything here is a *convenience*, never state anything depends on:
// localStorage throws outright in a locked-down/private-mode browser and
// silently comes back empty after a storage clear, so every read has a
// fallback and every write is best-effort. The player must behave
// identically when all of this returns nothing.
//
// Deliberately NOT server-side for quality/volume: those are device-shaped
// settings (this screen's comfortable volume, this connection's quality),
// and syncing them across devices would make a phone on cellular inherit
// a desktop's "1080p".
//
// Resume POSITION is the one exception, added 2026-10-11 (see
// routes.lua's M.save_watch_progress/M.watch_progress/M.continue_watching):
// unlike volume/quality, "where I got to in this video" is something a
// signed-in viewer actually wants to follow them to a second device --
// the "shared machine inherits someone else's position" concern doesn't
// apply once a server sync is scoped to the LOGGED-IN ACCOUNT rather than
// the browser, which is exactly what gates the calls below (readToken()
// null -- no session -- skips the network call entirely, so a signed-out/
// shared browser keeps the original local-only behavior unchanged). Local
// storage remains the fast/offline-tolerant path (every read here is still
// synchronous, nothing in the player ever waits on the network for a
// resume seek); the server call is a fire-and-forget mirror on top, not a
// replacement -- its only job is feeding M.continue_watching's cross-
// device rail and surviving a cleared browser.

const PREFIX = "nyxframe.player.";
const RESUME_KEY = `${PREFIX}resume`;
// Bounded so a heavy browsing session can't grow this entry without limit
// (a few hundred bytes each, trimmed oldest-first by last save).
const MAX_RESUME_ENTRIES = 240;
// Below this, "resuming" is indistinguishable from starting over and just
// looks like the player ignored the click.
const MIN_RESUME_SECONDS = 15;
// Past this fraction the viewer has effectively finished -- resuming 12
// seconds before the end is worse than replaying from the top.
const MAX_RESUME_FRACTION = 0.95;
// A short clip has no "pick up where I left off" problem worth solving.
const MIN_RESUMABLE_DURATION = 90;

// Lazily imported (not a top-level import) to keep this module's existing
// zero-network-dependency contract obvious at a glance -- every function
// below still works, synchronously, with no api.js in the picture, for a
// signed-out viewer or if this import ever fails to resolve.
let apiModulePromise = null;
function apiModule() {
  if (!apiModulePromise) apiModulePromise = import("../api.js");
  return apiModulePromise;
}

// Fire-and-forget: a slow/broken backend must never affect playback. Only
// called when readToken() is already known truthy (see call sites below).
function syncWatchProgressToServer(mediaId, positionSeconds, durationSeconds) {
  apiModule()
    .then(({ apiFetch }) => apiFetch(`/api/media/${mediaId}/watch-progress`, {
      method: "POST",
      body: JSON.stringify({ position_seconds: positionSeconds, duration_seconds: durationSeconds }),
    }))
    .catch(() => {});
}

function readRaw(key) {
  try {
    return window.localStorage.getItem(key);
  } catch (_error) {
    return null;
  }
}

function writeRaw(key, value) {
  try {
    window.localStorage.setItem(key, value);
  } catch (_error) {
    /* private mode / quota / disabled storage -- preferences just don't persist */
  }
}

export function getPlayerPref(name, fallback) {
  const raw = readRaw(PREFIX + name);
  if (raw === null) return fallback;
  try {
    const parsed = JSON.parse(raw);
    return parsed === null || parsed === undefined ? fallback : parsed;
  } catch (_error) {
    return fallback;
  }
}

export function setPlayerPref(name, value) {
  try {
    writeRaw(PREFIX + name, JSON.stringify(value));
  } catch (_error) {
    /* unserializable value -- nothing here is worth throwing over */
  }
}

export function getNumericPref(name, fallback, min, max) {
  const value = Number(getPlayerPref(name, fallback));
  if (!Number.isFinite(value)) return fallback;
  return Math.min(Math.max(value, min), max);
}

function readResumeMap() {
  const raw = readRaw(RESUME_KEY);
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (_error) {
    return {};
  }
}

function writeResumeMap(map) {
  const keys = Object.keys(map);
  if (keys.length > MAX_RESUME_ENTRIES) {
    keys
      .sort((a, b) => (map[a]?.at || 0) - (map[b]?.at || 0))
      .slice(0, keys.length - MAX_RESUME_ENTRIES)
      .forEach((key) => { delete map[key]; });
  }
  writeRaw(RESUME_KEY, JSON.stringify(map));
}

// Seconds to resume `mediaId` at, or 0 when there's nothing worth resuming.
export function getResumePosition(mediaId) {
  if (!mediaId) return 0;
  const entry = readResumeMap()[String(mediaId)];
  const time = Number(entry?.t);
  return Number.isFinite(time) && time >= MIN_RESUME_SECONDS ? time : 0;
}

// Records progress, or clears the entry when the position stops being
// worth resuming from (too near the start, too near the end, clip too
// short) -- so "finished watching" naturally cleans up after itself
// rather than leaving a stale near-the-end resume behind forever.
export function saveResumePosition(mediaId, time, duration) {
  if (!mediaId || !Number.isFinite(time) || !Number.isFinite(duration) || duration <= 0) return;
  const map = readResumeMap();
  const key = String(mediaId);
  const worthKeeping =
    duration >= MIN_RESUMABLE_DURATION &&
    time >= MIN_RESUME_SECONDS &&
    time <= duration * MAX_RESUME_FRACTION;
  if (!worthKeeping) {
    if (map[key] === undefined) return;
    delete map[key];
  } else {
    map[key] = { t: Math.floor(time), d: Math.floor(duration), at: Date.now() };
  }
  writeResumeMap(map);
  // Mirror to the account's server-side watch-progress row -- see this
  // file's header comment for why resume position (unlike quality/volume)
  // gets this. Only reached past the early-return above, so a never-saved,
  // still-trivial position never even fires the network call. readToken()
  // (dynamically imported, see apiModule() above) is the "signed in at
  // all" gate -- a signed-out viewer gets exactly the pre-2026-10-11
  // local-only behavior.
  import("../api.js").then(({ readToken }) => {
    if (readToken()) syncWatchProgressToServer(mediaId, time, duration);
  }).catch(() => {});
}

export function clearResumePosition(mediaId) {
  if (!mediaId) return;
  const map = readResumeMap();
  const key = String(mediaId);
  if (map[key] === undefined) return;
  delete map[key];
  writeResumeMap(map);
  // position_seconds=0 reads as "near start" server-side, which deletes
  // that row the same way finishing a video does -- see
  // M.save_watch_progress's own near_start/near_end branch.
  import("../api.js").then(({ readToken }) => {
    if (readToken()) syncWatchProgressToServer(mediaId, 0, 0);
  }).catch(() => {});
}
