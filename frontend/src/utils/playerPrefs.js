// Per-viewer, per-browser playback preferences and resume positions.
//
// Everything here is a *convenience*, never state anything depends on:
// localStorage throws outright in a locked-down/private-mode browser and
// silently comes back empty after a storage clear, so every read has a
// fallback and every write is best-effort. The player must behave
// identically when all of this returns nothing.
//
// Deliberately NOT server-side: these are device-shaped settings (this
// screen's comfortable volume, this connection's quality, where *this*
// browser got to in a video), and syncing them across devices would make
// a phone on cellular inherit a desktop's "1080p" and a shared machine
// inherit someone else's half-watched position.

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
}

export function clearResumePosition(mediaId) {
  if (!mediaId) return;
  const map = readResumeMap();
  const key = String(mediaId);
  if (map[key] === undefined) return;
  delete map[key];
  writeResumeMap(map);
}
