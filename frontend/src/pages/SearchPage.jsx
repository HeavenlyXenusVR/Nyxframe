import { useCallback, useEffect, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { Image as ImageIcon, Search as SearchIcon, Tag as TagIcon, Users as UsersIcon } from "lucide-react";
import { cachedApiFetch, toQuery } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { Avatar, EmptyState, Page, Pager, PresencePill, SkeletonGrid } from "../components/ui.jsx";
import { PAGE_SIZE } from "../config.js";

// One destination for every kind of "find the thing I'm thinking of".
// Before this the app had search scattered across pages that each queried
// one entity -- /users had a user box, the feed had a filter panel -- and
// no way at all to ask "where is that post" from wherever you happened to
// be. The topbar field and the command palette both land here.
//
// Tabs rather than one blended result list: media and people are answers
// to different questions, and interleaving them by some invented
// relevance score would bury whichever kind the viewer actually wanted.
// The counts on the tabs let them see at a glance which one has what
// they're after.
const TABS = [
  ["media", "Media", ImageIcon],
  ["users", "People", UsersIcon],
];

export function SearchPage({ ctx }) {
  const [params, setParams] = useSearchParams();
  const query = params.get("q") || "";
  const tab = TABS.some(([id]) => id === params.get("tab")) ? params.get("tab") : "media";
  const [draft, setDraft] = useState(query);
  const [media, setMedia] = useState([]);
  const [users, setUsers] = useState([]);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  const [hasNext, setHasNext] = useState(false);

  useEffect(() => { setDraft(query); setPage(1); }, [query]);

  const runSearch = useCallback(async () => {
    if (!query.trim()) {
      setMedia([]);
      setUsers([]);
      return;
    }
    setLoading(true);
    try {
      // Both entity types are fetched for any query, not just the active
      // tab's: the tab labels carry result counts, and a viewer who
      // searched a person's name should see "People 3" without first
      // guessing to click it.
      // limit+1 then slice, the same has-a-next-page trick the feeds
      // use -- /api/media is offset-based and returns no total.
      const [mediaData, userData] = await Promise.all([
        cachedApiFetch(`/api/media${toQuery({ q: query, limit: PAGE_SIZE + 1, offset: (page - 1) * PAGE_SIZE })}`, { ttl: 15_000 }),
        cachedApiFetch(`/api/users/search${toQuery({ q: query, limit: 36 })}`, { ttl: 15_000 }),
      ]);
      const rows = mediaData.media || [];
      setMedia(rows.slice(0, PAGE_SIZE));
      setHasNext(rows.length > PAGE_SIZE);
      setUsers(userData.users || []);
    } catch (_error) {
      setMedia([]);
      setUsers([]);
    } finally {
      setLoading(false);
    }
  }, [query, page]);

  useEffect(() => { runSearch(); }, [runSearch]);

  function submit(event) {
    event.preventDefault();
    setParams(draft.trim() ? { q: draft.trim(), tab } : {}, { replace: false });
  }

  function pickTab(next) {
    setParams(query ? { q: query, tab: next } : { tab: next }, { replace: true });
  }

  const counts = { media: media.length, users: users.length };

  return (
    <Page title="Search" eyebrow="Find" lede="Posts, tags and people across the whole site.">
      <form className="search-page-form" onSubmit={submit} role="search">
        <SearchIcon size={18} />
        <input
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          placeholder="Search posts, tags, or people…"
          aria-label="Search"
          autoFocus
        />
        <button type="submit">Search</button>
      </form>

      {query ? (
        <>
          <div className="search-tabs" role="tablist">
            {TABS.map(([id, label, Icon]) => (
              <button
                key={id}
                type="button"
                role="tab"
                aria-selected={tab === id}
                className={`search-tab${tab === id ? " active" : ""}`}
                onClick={() => pickTab(id)}
              >
                <Icon size={15} />
                {label}
                <span className="search-tab-count">{counts[id]}</span>
              </button>
            ))}
          </div>

          {tab === "media" ? (
            <>
              {loading && !media.length ? (
                <SkeletonGrid count={8} />
              ) : (
                <MediaGrid
                  ctx={ctx}
                  items={media}
                  loading={loading}
                  emptyTitle={`No posts match “${query}”`}
                  onItemUpdated={(updated) => setMedia((rows) => rows.map((row) => (row.id === updated.id ? updated : row)))}
                  onOpen={ctx.openLightbox}
                />
              )}
              <Pager page={page} hasNext={hasNext} loading={loading} onPage={setPage} />
            </>
          ) : users.length ? (
            <div className="search-user-list">
              {users.map((user) => (
                <Link key={user.id} className="search-user-row" to={`/users/${user.username}`}>
                  <Avatar user={user} />
                  <span className="search-user-copy">
                    <strong>{user.display_name || user.username}</strong>
                    <small>@{user.username}</small>
                  </span>
                  <PresencePill user={user} />
                </Link>
              ))}
            </div>
          ) : (
            <EmptyState title={`No people match “${query}”`} />
          )}
        </>
      ) : (
        <div className="search-hint">
          <TagIcon size={16} />
          <span>
            Type anything above, or press <kbd>{navigator.platform?.includes("Mac") ? "⌘" : "Ctrl"}</kbd> + <kbd>K</kbd> anywhere on the
            site to jump straight to a page, a post or a person.
          </span>
        </div>
      )}
    </Page>
  );
}
