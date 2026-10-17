import { Link } from "react-router-dom";
import { Page } from "../components/ui.jsx";
import { apiUrl } from "../api.js";

// Static page -- deliberately no backend call. "Optimization: cache the
// manifest" for this feature just means never generating one at request
// time at all: this content changes only when a route is added/removed,
// which is a code change anyway, so it's checked into the same commit as
// the route instead of being computed and cached separately.
const ENDPOINTS = [
  { method: "GET", path: "/api/media", desc: "List/search public media. Supports q, tags, category_id, media_kind, color, sort, limit, offset." },
  { method: "GET", path: "/api/media/:id", desc: "A single post's full detail." },
  { method: "GET", path: "/api/media/trending", desc: "Trending posts over a rolling window (days=1|7|30)." },
  { method: "GET", path: "/api/media/random", desc: "One random public post you're allowed to see." },
  { method: "GET", path: "/api/media/:id/thumb", desc: "A post's thumbnail (?w= for width)." },
  { method: "GET", path: "/api/media/:id/file", desc: "The original media file, Range-servable." },
  { method: "GET", path: "/api/users/:username", desc: "A public profile." },
  { method: "GET", path: "/api/users/search", desc: "Search users by username/display name/bio." },
  { method: "GET", path: "/api/leaderboard", desc: "Top creators by engagement (window=7d|30d|all)." },
  { method: "GET", path: "/api/status", desc: "Service health and incident history." },
];

export function ApiDocsPage() {
  const origin = typeof window !== "undefined" ? window.location.origin : "";
  const exampleUrl = apiUrl("/api/media?limit=5");

  return (
    <Page
      title="API"
      eyebrow="Developers"
      lede="A scoped, read-only key for pulling your own public data into something else."
    >
      <div className="side-box">
        <div className="section-head"><h2>Authentication</h2></div>
        <p>
          Create a scoped API key from <Link to="/settings">Settings</Link>. It only ever sees what your
          own account could already see publicly -- it cannot post, edit, delete, or act as you in any way.
          Pass it as a query parameter on any GET endpoint below:
        </p>
        <pre className="code-block">{`curl "${origin}/api/media?limit=5&key=gk_YOUR_KEY_HERE"`}</pre>
        <p>Keys can be revoked at any time from the same Settings panel, with no effect on anything else.</p>
      </div>

      <div className="side-box">
        <div className="section-head"><h2>Personal feed (RSS)</h2></div>
        <p>
          A keyed RSS feed of your own uploads, suitable for a feed reader -- the one surface this key
          type is actually designed around end-to-end:
        </p>
        <pre className="code-block">{`${origin}/feed/me.xml?key=gk_YOUR_KEY_HERE`}</pre>
      </div>

      <div className="section-head"><h2>Read-only endpoints</h2></div>
      <div className="api-endpoint-table">
        {ENDPOINTS.map((ep) => (
          <div className="api-endpoint-row" key={ep.method + ep.path}>
            <span className={`api-method api-method-${ep.method.toLowerCase()}`}>{ep.method}</span>
            <code>{ep.path}</code>
            <span className="api-endpoint-desc">{ep.desc}</span>
          </div>
        ))}
      </div>
      <p className="incident-meta">
        Try it now: <a href={exampleUrl} target="_blank" rel="noreferrer">{exampleUrl}</a>
      </p>
    </Page>
  );
}
