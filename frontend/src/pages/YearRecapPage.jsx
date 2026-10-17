import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Sparkles } from "lucide-react";
import { apiFetch } from "../api.js";
import { EmptyState, Metric, Notice, Page, RequireLogin } from "../components/ui.jsx";

const CURRENT_YEAR = new Date().getUTCFullYear();
// Matches routes.lua's M.year_recap lower bound (pg_add_year_recap_cache.sql
// has no earlier data to recap anyway).
const EARLIEST_YEAR = 2020;

export function YearRecapPage({ ctx }) {
  const [year, setYear] = useState(CURRENT_YEAR);
  const [recap, setRecap] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!ctx.user) return;
    let cancelled = false;
    setLoading(true);
    setError("");
    apiFetch(`/api/me/year-recap?year=${year}`)
      .then((data) => { if (!cancelled) setRecap(data); })
      .catch((err) => { if (!cancelled) setError(err.message); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [ctx.user, year]);

  if (!ctx.user) return <RequireLogin />;

  const years = [];
  for (let y = CURRENT_YEAR; y >= EARLIEST_YEAR; y -= 1) years.push(y);

  return (
    <Page
      title="Year in Review"
      eyebrow="Recap"
      lede={`Your ${year} on the gallery, at a glance.`}
      actions={(
        <select value={year} onChange={(event) => setYear(Number(event.target.value))}>
          {years.map((y) => <option key={y} value={y}>{y}</option>)}
        </select>
      )}
    >
      {error ? <Notice kind="error" onRetry={() => setYear((y) => y)}>{error}</Notice> : null}
      {!loading && recap && recap.post_count === 0 ? (
        <EmptyState icon={Sparkles} title={`Nothing posted in ${year}`} hint="Upload something and come back next year." />
      ) : (
        <>
          <div className="stat-strip">
            <Metric label="Posts" value={loading ? "…" : recap?.post_count ?? 0} />
            <Metric label="Views" value={loading ? "…" : recap?.total_views ?? 0} />
            <Metric label="Likes received" value={loading ? "…" : recap?.total_likes_received ?? 0} />
            <Metric label="Comments received" value={loading ? "…" : recap?.total_comments_received ?? 0} />
            <Metric label="Likes given" value={loading ? "…" : recap?.likes_given ?? 0} />
          </div>
          {recap?.top_tag ? (
            <p className="page-lede">Your most-used tag this year was <strong>#{recap.top_tag}</strong>.</p>
          ) : null}
          {recap?.top_post ? (
            <div className="side-box">
              <div className="section-head"><h2>Your top post of {year}</h2></div>
              <Link to={`/media/${recap.top_post.id}`} className="recap-top-post">
                {recap.top_post.thumb_url ? <img src={recap.top_post.thumb_url} alt={recap.top_post.title} loading="lazy" /> : null}
                <div>
                  <h3>{recap.top_post.title}</h3>
                  <p>{recap.top_post.like_count} likes · {recap.top_post.views} views</p>
                </div>
              </Link>
            </div>
          ) : null}
          {recap?.member_since ? (
            <p className="page-lede">Member since {new Date(recap.member_since).toLocaleDateString()}.</p>
          ) : null}
        </>
      )}
    </Page>
  );
}
