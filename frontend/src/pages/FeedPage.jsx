import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { UserPlus } from "lucide-react";
import { apiFetch, cachedApiFetch, prefetchApi, toQuery } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { PAGE_SIZE } from "../config.js";
import { MediaGrid } from "../components/media.jsx";
import { EmptyState, Notice, Page, Pager, RequireLogin } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";
import { reconcileList } from "../utils/reconcile.js";

function pageSizeFor(settings) {
  const parsed = Number(settings?.items_per_page);
  if (!Number.isFinite(parsed)) return PAGE_SIZE;
  return Math.min(60, Math.max(12, Math.round(parsed)));
}

export function FeedPage({ ctx, mode }) {
  const [page, setPage] = useState(1);
  const [items, setItems] = useState([]);
  const [hasNext, setHasNext] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const title = mode === "liked" ? "Liked" : "Following";
  const endpoint = mode === "liked" ? "/api/me/likes" : "/api/feed/following";
  const pageSize = pageSizeFor(ctx.settings);

  const userId = ctx.user?.id;
  const handleItemUpdated = useCallback((item) => setItems((rows) => replaceMedia(rows, item)), []);

  // Latest request wins: flipping pages quickly (or a background refresh
  // overlapping a page change) must not let an older response land last.
  const requestRef = useRef(0);
  // Last {count, latest} seen from /api/feed/signal -- null means "no
  // baseline yet", which always falls through to a real fetch below.
  const feedSignalRef = useRef(null);
  const loadFeed = useCallback(({ background = false } = {}) => {
    if (!userId) return Promise.resolve();
    const requestId = ++requestRef.current;
    return (async () => {
      if (!background) setLoading(true);
      if (!background) setError("");
      try {
        const path = `${endpoint}${toQuery({ limit: pageSize + 1, offset: (page - 1) * pageSize })}`;
        const data = background
          ? await apiFetch(path)
          : await cachedApiFetch(path, { ttl: 20_000, staleTtl: 3 * 60_000 });
        if (requestId !== requestRef.current) return;
        const rows = data.media || [];
        setItems((current) => reconcileList(current, rows.slice(0, pageSize)));
        setHasNext(rows.length > pageSize);
        preloadMediaAssets(rows, { limit: 6 });
        if (rows.length > pageSize) {
          prefetchApi(`${endpoint}${toQuery({ limit: pageSize + 1, offset: page * pageSize })}`, { ttl: 30_000, staleTtl: 3 * 60_000 });
        }
      } catch (fetchError) {
        if (!background && requestId === requestRef.current) setError(fetchError.message);
      } finally {
        if (!background && requestId === requestRef.current) setLoading(false);
      }
    })();
  }, [userId, endpoint, page, pageSize]);

  useEffect(() => {
    loadFeed();
  }, [loadFeed]);

  // Checked on every poll tick BEFORE paying for a full loadFeed() --
  // that query costs a per-row correlated subquery (likes/comments/
  // bookmarked/liked) plus two JOINs, which is wasted work on every tick
  // that comes back identical to what's already on screen. /api/feed/signal
  // is a plain COUNT+MAX(created_at) with no joins at all; only a change
  // there triggers the real fetch. A like/comment landing on an
  // already-visible post doesn't move this signal (neither touches
  // media_items), so it surfaces on the next tick that DOES see a change,
  // or on the viewer's own next real page load -- see feed_signal's own
  // header comment in routes.lua for why that's an accepted tradeoff.
  const checkFeedSignal = useCallback(async () => {
    if (!userId) return;
    const kind = mode === "liked" ? "liked" : "following";
    const signal = await apiFetch(`/api/feed/signal${toQuery({ kind })}`);
    const prev = feedSignalRef.current;
    feedSignalRef.current = signal;
    if (prev && prev.count === signal.count && prev.latest === signal.latest) return;
    await loadFeed({ background: true });
  }, [userId, mode, loadFeed]);
  useLiveRefresh(checkFeedSignal, { enabled: Boolean(ctx.user) && page === 1, interval: 22_000 });

  if (!ctx.user) return <RequireLogin />;

  const followingEmpty = !loading && !items.length && mode === "following";
  const likedEmpty = !loading && !items.length && mode === "liked";

  return (
    <Page title={title} eyebrow="Feed">
      {error ? <Notice kind="error" onRetry={() => loadFeed()}>{error}</Notice> : null}
      {followingEmpty ? (
        <div className="empty-state feed-empty-cta">
          <UserPlus size={28} />
          <h2>No posts from people you follow yet</h2>
          <p>Follow some creators to see their latest uploads here.</p>
          <Link className="button-link primary" to="/users"><UserPlus size={16} />Browse Creators</Link>
        </div>
      ) : likedEmpty ? (
        <EmptyState
            title="You haven't liked any posts yet"
            hint="Anything you like while browsing collects here."
            action={<Link className="button-link primary" to="/">Browse Discover</Link>}
          />
      ) : (
        <MediaGrid ctx={ctx} items={items} loading={loading} emptyTitle={mode === "liked" ? "No liked posts yet" : "No following posts yet"} onItemUpdated={handleItemUpdated} onOpen={ctx.openLightbox} />
      )}
      <Pager page={page} hasNext={hasNext} loading={loading} onPage={setPage} />
    </Page>
  );
}
