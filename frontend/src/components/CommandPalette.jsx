import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  Folder,
  Grid3X3,
  Heart,
  Home,
  Image as ImageIcon,
  MessageCircle,
  Rocket,
  Search as SearchIcon,
  Settings,
  ShieldAlert,
  Sparkles,
  TrendingUp,
  Upload,
  UserPlus,
  Users,
} from "lucide-react";
import { cachedApiFetch, toQuery } from "../api.js";
import { Avatar } from "./ui.jsx";
import { thumbUrl } from "../utils/media.js";

// Ctrl/Cmd+K: one keystroke to anywhere.
//
// The site has seventeen routes and a primary nav that already can't fit
// them on a phone. Adding more chrome would make that worse, so the
// palette carries the breadth instead: every destination is reachable by
// typing two or three letters of its name, and the same box also
// searches real content, so "that post about foxes" and "the settings
// page" are the same gesture.
//
// Destinations are filtered locally (they're a fixed list of a dozen and
// filtering them over the network would be absurd); media and people are
// fetched, debounced, and only once a query is long enough to be worth a
// request.
const DESTINATIONS = [
  { to: "/", label: "Discover", icon: Home, keywords: "home feed browse" },
  { to: "/trending", label: "Trending", icon: TrendingUp, keywords: "popular hot" },
  { to: "/collections", label: "Collections", icon: Folder, keywords: "saved sets albums" },
  { to: "/users", label: "People", icon: Users, keywords: "users members profiles" },
  { to: "/following", label: "Following", icon: Sparkles, keywords: "feed subscriptions" },
  { to: "/liked", label: "Liked", icon: Heart, keywords: "favourites hearts" },
  { to: "/friends", label: "Friends", icon: UserPlus, keywords: "requests", auth: true },
  { to: "/messages", label: "Messages", icon: MessageCircle, keywords: "dm chat inbox", auth: true },
  { to: "/studio", label: "Creator Studio", icon: Grid3X3, keywords: "my uploads manage posts", auth: true },
  { to: "/upload", label: "Upload", icon: Upload, keywords: "new post add", auth: true },
  { to: "/settings", label: "Settings", icon: Settings, keywords: "preferences theme account", auth: true },
  { to: "/admin", label: "Admin", icon: ShieldAlert, keywords: "moderation health", owner: true },
  { to: "/other-projects", label: "My Other Projects", icon: Rocket, keywords: "lumisound swarmpanel apps" },
];

// Subsequence match, not substring: "cst" finds "Creator Studio" the way
// an editor's file switcher would, which is the interaction people
// already have muscle memory for from every other palette.
function fuzzyScore(haystack, needle) {
  if (!needle) return 0;
  const target = haystack.toLowerCase();
  const query = needle.toLowerCase();
  const direct = target.indexOf(query);
  if (direct === 0) return 1000;
  if (direct > 0) return 800 - direct;
  let index = 0;
  let score = 400;
  let lastHit = -1;
  for (const character of query) {
    const hit = target.indexOf(character, index);
    if (hit < 0) return -1;
    // Reward adjacency so "med" prefers "Media" over a string that
    // merely happens to contain m, e and d far apart.
    if (lastHit >= 0) score -= Math.min(hit - lastHit - 1, 20);
    lastHit = hit;
    index = hit + 1;
  }
  return score;
}

export function CommandPalette({ ctx, open, onClose }) {
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState({ media: [], users: [] });
  const [active, setActive] = useState(0);
  const inputRef = useRef(null);
  const listRef = useRef(null);

  useEffect(() => {
    if (!open) return;
    setQuery("");
    setResults({ media: [], users: [] });
    setActive(0);
    // rAF, not a bare focus(): the dialog is mounted in the same commit,
    // and focusing a node the browser hasn't laid out yet is silently
    // dropped in Safari.
    const frame = requestAnimationFrame(() => inputRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [open]);

  // Debounced remote lookup. Two characters is the floor: a single letter
  // matches most of the library and the request is pure waste.
  useEffect(() => {
    if (!open) return undefined;
    const trimmed = query.trim();
    if (trimmed.length < 2) {
      setResults({ media: [], users: [] });
      return undefined;
    }
    let cancelled = false;
    const timer = setTimeout(async () => {
      try {
        const [mediaData, userData] = await Promise.all([
          cachedApiFetch(`/api/media${toQuery({ q: trimmed, limit: 6 })}`, { ttl: 20_000 }),
          cachedApiFetch(`/api/users/search${toQuery({ q: trimmed, limit: 4 })}`, { ttl: 20_000 }),
        ]);
        if (cancelled) return;
        setResults({ media: (mediaData.media || []).slice(0, 6), users: (userData.users || []).slice(0, 4) });
      } catch (_error) {
        if (!cancelled) setResults({ media: [], users: [] });
      }
    }, 220);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [query, open]);

  const rows = useMemo(() => {
    const trimmed = query.trim();
    const destinations = DESTINATIONS.filter((item) => {
      if (item.owner && !ctx.user?.site_owner) return false;
      if (item.auth && !ctx.user) return false;
      return true;
    })
      .map((item) => ({ item, score: trimmed ? Math.max(fuzzyScore(item.label, trimmed), fuzzyScore(item.keywords, trimmed) - 100) : 500 }))
      .filter((entry) => entry.score >= 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, trimmed ? 5 : DESTINATIONS.length)
      .map((entry) => ({ kind: "page", key: `page:${entry.item.to}`, ...entry.item }));

    const media = results.media.map((item) => ({
      kind: "media",
      key: `media:${item.id}`,
      to: `/media/${item.id}`,
      label: item.title || `Post ${item.id}`,
      sub: item.display_name || item.username || "",
      item,
    }));
    const users = results.users.map((user) => ({
      kind: "user",
      key: `user:${user.id}`,
      to: `/users/${user.username}`,
      label: user.display_name || user.username,
      sub: `@${user.username}`,
      user,
    }));

    const all = [...destinations, ...users, ...media];
    // Always offer the full-search escape hatch, so no query is ever a
    // dead end -- the palette shows a handful of hits, /search shows all
    // of them.
    if (trimmed) {
      all.push({ kind: "search", key: "search", to: `/search?q=${encodeURIComponent(trimmed)}`, label: `Search for “${trimmed}”` });
    }
    return all;
  }, [ctx.user, query, results]);

  useEffect(() => { setActive(0); }, [rows.length]);

  const choose = useCallback((row) => {
    if (!row) return;
    onClose();
    navigate(row.to);
  }, [navigate, onClose]);

  function onKeyDown(event) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActive((index) => (index + 1) % Math.max(rows.length, 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setActive((index) => (index - 1 + rows.length) % Math.max(rows.length, 1));
    } else if (event.key === "Enter") {
      event.preventDefault();
      choose(rows[active]);
    } else if (event.key === "Escape") {
      event.preventDefault();
      onClose();
    }
  }

  // Keep the highlighted row in view when arrowing past the fold.
  useEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const node = list.querySelector("[data-active='true']");
    if (node?.scrollIntoView) node.scrollIntoView({ block: "nearest" });
  }, [active]);

  if (!open) return null;

  return (
    <div className="cmdk-backdrop" role="presentation" onClick={onClose}>
      <div
        className="cmdk-panel"
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="cmdk-input-row">
          <SearchIcon size={18} />
          <input
            ref={inputRef}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={onKeyDown}
            placeholder="Jump to a page, post or person…"
            aria-label="Command palette search"
            // The listbox is rendered below and driven by aria-activedescendant
            // so arrow keys can move a highlight without ever moving focus
            // out of the text field.
            role="combobox"
            aria-expanded="true"
            aria-controls="cmdk-list"
            aria-activedescendant={rows[active] ? `cmdk-row-${active}` : undefined}
            autoComplete="off"
          />
          <kbd>esc</kbd>
        </div>
        <ul className="cmdk-list" id="cmdk-list" role="listbox" ref={listRef}>
          {rows.length === 0 ? (
            <li className="cmdk-empty">No matches</li>
          ) : (
            rows.map((row, index) => (
              <li key={row.key}>
                <button
                  type="button"
                  id={`cmdk-row-${index}`}
                  role="option"
                  aria-selected={index === active}
                  data-active={index === active}
                  className={`cmdk-row${index === active ? " active" : ""}`}
                  onMouseEnter={() => setActive(index)}
                  onClick={() => choose(row)}
                >
                  <span className="cmdk-row-icon">
                    {row.kind === "page" && row.icon ? <row.icon size={16} /> : null}
                    {row.kind === "search" ? <SearchIcon size={16} /> : null}
                    {row.kind === "user" ? <Avatar user={row.user} compact /> : null}
                    {row.kind === "media" ? (
                      row.item?.thumb_url || row.item?.preview_url ? (
                        <img src={thumbUrl(row.item, 64)} alt="" loading="lazy" />
                      ) : (
                        <ImageIcon size={16} />
                      )
                    ) : null}
                  </span>
                  <span className="cmdk-row-copy">
                    <strong>{row.label}</strong>
                    {row.sub ? <small>{row.sub}</small> : null}
                  </span>
                  <span className="cmdk-row-kind">
                    {row.kind === "page" ? "Page" : row.kind === "user" ? "Person" : row.kind === "media" ? "Post" : "Search"}
                  </span>
                </button>
              </li>
            ))
          )}
        </ul>
      </div>
    </div>
  );
}
