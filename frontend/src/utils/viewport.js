// One IntersectionObserver per rootMargin, shared by every element that
// subscribes, instead of one observer per card. A long feed mounts hundreds
// of MediaCards; each owning its own observer meant hundreds of observers
// the browser has to run intersection checks for on every scroll frame.

const observers = new Map();

function observerFor(rootMargin) {
  let entry = observers.get(rootMargin);
  if (entry) return entry;
  const callbacks = new Map();
  const observer = new IntersectionObserver((records) => {
    for (const record of records) {
      const callback = callbacks.get(record.target);
      if (callback) callback(record);
    }
  }, { rootMargin });
  entry = { observer, callbacks };
  observers.set(rootMargin, entry);
  return entry;
}

// Returns an unsubscribe function. Falls back to reporting "visible" once
// where IntersectionObserver isn't available, so content still loads.
export function observeViewport(node, callback, { rootMargin = "200px" } = {}) {
  if (!node) return () => {};
  if (typeof IntersectionObserver === "undefined") {
    callback({ isIntersecting: true, target: node });
    return () => {};
  }
  const entry = observerFor(rootMargin);
  entry.callbacks.set(node, callback);
  entry.observer.observe(node);
  return () => {
    entry.callbacks.delete(node);
    entry.observer.unobserve(node);
  };
}
