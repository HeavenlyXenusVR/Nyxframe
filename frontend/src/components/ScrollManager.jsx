import { useEffect, useRef } from "react";
import { useLocation, useNavigationType } from "react-router-dom";

// Scroll position across navigation. The app had none of this, and the
// two symptoms were opposite halves of the same missing feature:
//
//  * A client-side route change doesn't reset scroll, so opening a page
//    from halfway down another one landed you halfway down the new one.
//  * Going back put you at the top instead of where you were. The
//    browser's own scroll restoration can't help: it fires while the
//    route's data is still being fetched, so the document is a few
//    hundred pixels tall and the restore gets clamped to zero.
//
// So: remember a position per history entry, reset to the top on a new
// navigation, and restore on back/forward -- retrying until the page has
// actually grown tall enough to honour it.
//
// The REPLACE case is the subtle one, and cost a debugging round to
// find. Several pages (the feed's filter/sort sync, for one) rewrite
// their own URL with `navigate(..., { replace: true })` immediately
// after mounting. That is a new location.key, so a naive "any
// navigation scrolls to top" rule fired a fraction of a second AFTER a
// successful back-restore and threw it away -- measured: POP found its
// 1400px target, then a REPLACE put the viewer back at 0. A REPLACE is
// the same page editing its own address, never a new destination, so it
// must neither reset the scroll nor cancel a restore already in flight.
const RESTORE_TIMEOUT_MS = 2500;
// A session can accumulate a lot of history entries; nothing here is
// worth unbounded memory.
const MAX_TRACKED_ENTRIES = 60;

export function ScrollManager() {
  const location = useLocation();
  const navigationType = useNavigationType();
  // Keyed by history ENTRY, not by path, so visiting the same feed twice
  // keeps two distinct positions -- what a viewer going back through
  // several posts expects.
  const positions = useRef(new Map());
  const currentKey = useRef(location.key);
  // Set while the rAF loop below is driving the scroll, so the listener
  // that records positions doesn't overwrite the saved target with the
  // intermediate values the restore itself produces.
  const restoring = useRef(false);
  // Survives a REPLACE landing in the middle of a restore.
  const pendingTarget = useRef(null);

  useEffect(() => {
    // Take over from the browser: otherwise its own (mistimed) restore
    // races the one below and usually wins with a clamped value.
    if (!("scrollRestoration" in window.history)) return undefined;
    const previous = window.history.scrollRestoration;
    window.history.scrollRestoration = "manual";
    return () => { window.history.scrollRestoration = previous; };
  }, []);

  // Record where we are, continuously. Not in an effect cleanup: that
  // runs after React has committed the next route, by which point
  // window.scrollY may already have been reset by the new layout.
  useEffect(() => {
    currentKey.current = location.key;
    const onScroll = () => {
      if (restoring.current) return;
      const map = positions.current;
      map.set(currentKey.current, window.scrollY);
      if (map.size > MAX_TRACKED_ENTRIES) {
        // Map iteration is insertion-ordered, so the first key is the
        // least recently first-seen entry.
        map.delete(map.keys().next().value);
      }
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, [location.key]);

  useEffect(() => {
    if (navigationType === "PUSH") {
      pendingTarget.current = null;
      restoring.current = false;
      window.scrollTo(0, 0);
      return undefined;
    }
    if (navigationType === "POP") {
      pendingTarget.current = positions.current.get(location.key) || null;
      if (!pendingTarget.current) {
        window.scrollTo(0, 0);
        return undefined;
      }
    }
    // POP with a target, or a REPLACE while one is still pending.
    const target = pendingTarget.current;
    if (!target) return undefined;

    // The page grows as its data arrives, so one scrollTo isn't enough --
    // keep nudging until the document can actually reach the target, or
    // until it's clear it never will (a post that was deleted, a feed
    // that now returns fewer rows).
    let frame = null;
    restoring.current = true;
    const deadline = performance.now() + RESTORE_TIMEOUT_MS;
    const finish = () => {
      restoring.current = false;
      pendingTarget.current = null;
    };
    const attempt = () => {
      const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
      window.scrollTo(0, Math.min(target, Math.max(maxScroll, 0)));
      if (window.scrollY >= target - 2) { finish(); return; }
      if (performance.now() >= deadline) { finish(); return; }
      frame = requestAnimationFrame(attempt);
    };
    frame = requestAnimationFrame(attempt);
    return () => {
      if (frame) cancelAnimationFrame(frame);
      // Deliberately does NOT clear pendingTarget: this cleanup also
      // runs for the REPLACE that interrupts a restore, and the next
      // pass through this effect is what resumes it.
      restoring.current = false;
    };
  }, [location.key, navigationType]);

  return null;
}
