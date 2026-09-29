import { useEffect, useRef } from "react";

// Background polling shared by every live surface (feeds, profile, social,
// notifications, messages, lookups).
//
//  * Paused while the tab is hidden or the browser is offline.
//  * A timeout chain instead of setInterval, so a slow request can never
//    stack ticks on top of each other.
//  * A little jitter, so the dozen pollers mounted at once don't all fire
//    in the same frame (and hit the backend in one burst) every cycle.
//  * Exponential backoff while the callback keeps failing (backend restart,
//    rotated tunnel), reset on the first success -- no hammering a server
//    that's down.
//  * Returning to the tab refreshes right away, but only if the last run
//    is at least a few seconds old, so rapid tab-switching doesn't spam.
const MAX_BACKOFF_FACTOR = 8;
const RESUME_MIN_GAP_MS = 4_000;

export function useLiveRefresh(callback, { enabled = true, interval = 20_000, immediate = false } = {}) {
  const callbackRef = useRef(callback);

  useEffect(() => {
    callbackRef.current = callback;
  }, [callback]);

  useEffect(() => {
    if (!enabled || typeof window === "undefined") return undefined;
    let stopped = false;
    let timer = 0;
    let inFlight = false;
    let failures = 0;
    let lastRunAt = 0;

    const schedule = () => {
      if (stopped) return;
      window.clearTimeout(timer);
      const factor = Math.min(MAX_BACKOFF_FACTOR, 2 ** failures);
      const jitter = 0.9 + Math.random() * 0.2;
      timer = window.setTimeout(tick, Math.round(interval * factor * jitter));
    };

    const run = () => {
      if (stopped || inFlight) return;
      if (document.hidden || navigator.onLine === false) return;
      inFlight = true;
      lastRunAt = Date.now();
      Promise.resolve()
        .then(() => callbackRef.current?.())
        .then(
          () => { failures = 0; },
          () => { failures = Math.min(failures + 1, 6); },
        )
        .finally(() => {
          inFlight = false;
        });
    };

    function tick() {
      run();
      schedule();
    }

    const resume = () => {
      if (document.hidden) return;
      if (Date.now() - lastRunAt < RESUME_MIN_GAP_MS) return;
      failures = 0;
      run();
      schedule();
    };

    if (immediate) run();
    schedule();
    document.addEventListener("visibilitychange", resume);
    window.addEventListener("online", resume);

    return () => {
      stopped = true;
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", resume);
      window.removeEventListener("online", resume);
    };
  }, [enabled, immediate, interval]);
}
