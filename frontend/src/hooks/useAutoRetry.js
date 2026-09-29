import { useEffect, useRef } from "react";

// Retries a failed "load next page" on its own, with exponential backoff:
// 2s, 4s, 8s, 16s, then every 30s. `failures` is how many times in a row
// the request has failed (0 = nothing to retry); the caller resets it to 0
// on success or when the list starts over. While the tab is hidden or the
// browser is offline the retry waits, and fires as soon as the tab is back
// / the connection returns rather than burning attempts in the background.
const BASE_DELAY_MS = 2_000;
const MAX_DELAY_MS = 30_000;

export function retryDelayMs(failures) {
  return Math.min(MAX_DELAY_MS, BASE_DELAY_MS * 2 ** Math.max(0, failures - 1));
}

export function useAutoRetry({ failures, enabled = true, onRetry }) {
  const onRetryRef = useRef(onRetry);
  onRetryRef.current = onRetry;

  useEffect(() => {
    if (!enabled || !failures || typeof window === "undefined") return undefined;
    let done = false;
    let timer = 0;

    const blocked = () => document.hidden || navigator.onLine === false;
    const fire = () => {
      if (done) return;
      if (blocked()) return; // wait for the listeners below
      done = true;
      cleanup();
      onRetryRef.current?.();
    };
    const onResume = () => { if (!blocked()) fire(); };
    function cleanup() {
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", onResume);
      window.removeEventListener("online", onResume);
    }

    timer = window.setTimeout(() => {
      if (blocked()) {
        document.addEventListener("visibilitychange", onResume);
        window.addEventListener("online", onResume);
        return;
      }
      fire();
    }, retryDelayMs(failures));
    // Coming back online is a strong signal the next try will work -- don't
    // sit out the rest of a long backoff.
    window.addEventListener("online", onResume);

    return () => {
      done = true;
      cleanup();
    };
  }, [enabled, failures]);
}
