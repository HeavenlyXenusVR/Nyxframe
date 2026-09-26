import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { RefreshCw, TrendingUp } from "lucide-react";
import { apiFetch, cachedApiFetch, clearApiCache, toQuery } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { EmptyState, Notice, Page, Segmented } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";

const WINDOWS = [["1", "24h"], ["7", "7 days"], ["30", "30 days"]];
const LEADERBOARD_WINDOWS = [["7d", "7 days"], ["30d", "30 days"], ["all", "All time"]];

function Leaderboard() {
  const [window_, setWindow] = useState("30d");
  const [creators, setCreators] = useState([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await cachedApiFetch(`/api/leaderboard${toQuery({ window: window_ })}`, { ttl: 60_000, staleTtl: 5 * 60_000 });
      setCreators(data.creators || []);
    } catch {
      setCreators([]);
    } finally {
      setLoading(false);
    }
  }, [window_]);

  useEffect(() => {
    load();
  }, [load]);

  return (
    <div className="leaderboard">
      <div className="leaderboard-header">
        <h3>Top creators</h3>
        <Segmented value={window_} onChange={setWindow} options={LEADERBOARD_WINDOWS} />
      </div>
      {loading ? null : !creators.length ? (
        <p className="leaderboard-empty">No creator activity in this window yet.</p>
      ) : (
        <ol className="leaderboard-list">
          {creators.map((c, i) => (
            <li key={c.id}>
              <span className="leaderboard-rank">{i + 1}</span>
              {c.user_avatar_url ? <img src={c.user_avatar_url} alt="" /> : <span className="leaderboard-avatar-fallback" />}
              <Link to={`/users/${c.username}`} className="leaderboard-name">{c.display_name || c.username}</Link>
              <span className="leaderboard-stats">{c.total_views.toLocaleString()} views · {c.total_likes.toLocaleString()} likes</span>
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}

export function TrendingPage({ ctx }) {
  const [days, setDays] = useState("7");
  // The window's ranking was hard-capped at 30 posts with no way to see
  // past it -- a dead end on a busy week, and the endpoint takes a limit.
  const [limit, setLimit] = useState(30);
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const handleItemUpdated = useCallback((item) => setItems((rows) => replaceMedia(rows, item)), []);

  const loadTrending = useCallback(async ({ fresh = false } = {}) => {
    setLoading(true);
    setError("");
    try {
      const path = `/api/media/trending${toQuery({ days, limit })}`;
      const data = fresh
        ? await apiFetch(path)
        : await cachedApiFetch(path, { ttl: 30_000, staleTtl: 5 * 60_000 });
      const rows = data.media || [];
      setItems(rows);
      preloadMediaAssets(rows, { limit: 6 });
    } catch (fetchError) {
      setError(fetchError.message);
      setItems([]);
    } finally {
      setLoading(false);
    }
  }, [days, limit]);

  useEffect(() => {
    loadTrending();
  }, [loadTrending]);

  // A new window starts over at the default depth rather than inheriting
  // however far the viewer had expanded the previous one.
  useEffect(() => { setLimit(30); }, [days]);

  return (
    <Page
      title="Trending"
      eyebrow="Discover"
      lede="Posts ranked by views, likes, and comments within the selected window."
      actions={(
        <>
          <Segmented value={days} onChange={setDays} options={WINDOWS} />
          <button type="button" onClick={() => { clearApiCache("/api/media/trending"); loadTrending({ fresh: true }); }} disabled={loading}>
            <RefreshCw size={16} />Refresh
          </button>
        </>
      )}
    >
      {error ? <Notice kind="error" onRetry={() => loadTrending({ fresh: true })}>{error}</Notice> : null}
      {!loading && !items.length && !error ? (
        // A quiet week is the normal case on a small archive, and the
        // default window is the shortest one -- so the most common way to
        // arrive here is to land on an empty page while a wider window is
        // full. Offer the widening instead of leaving a dead end.
        <EmptyState
          icon={TrendingUp}
          title="Nothing trending in this window yet"
          hint={days === "30" ? "Try a different sort on Discover to find older posts." : "Nothing has picked up views or likes in this period."}
          action={days !== "30" ? (
            <button type="button" className="button-link" onClick={() => setDays("30")}>Look at the last 30 days</button>
          ) : (
            <Link className="button-link" to="/">Browse Discover</Link>
          )}
        />
      ) : (
        <>
          <MediaGrid ctx={ctx} items={items} loading={loading} emptyTitle="Nothing trending yet" onItemUpdated={handleItemUpdated} onOpen={ctx.openLightbox} />
          {/* Only offered while the server is still filling the window:
              fewer rows than asked for means there is nothing more. */}
          {items.length >= limit ? (
            <div className="load-more-row">
              <button type="button" onClick={() => setLimit((value) => value + 30)} disabled={loading}>
                Show more
              </button>
            </div>
          ) : null}
        </>
      )}
      <Leaderboard />
    </Page>
  );
}
