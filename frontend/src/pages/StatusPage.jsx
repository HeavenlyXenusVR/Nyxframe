import { useEffect, useState } from "react";
import { CheckCircle2, AlertTriangle, XCircle } from "lucide-react";
import { cachedApiFetch } from "../api.js";
import { EmptyState, Notice, Page } from "../components/ui.jsx";

function severityIcon(severity) {
  if (severity === "critical") return <XCircle size={16} className="status-icon-critical" />;
  if (severity === "major") return <AlertTriangle size={16} className="status-icon-major" />;
  return <AlertTriangle size={16} className="status-icon-minor" />;
}

export function StatusPage() {
  const [status, setStatus] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    // Short TTL, not live-polled: a status page should feel current
    // without hammering the backend every time someone glances at it.
    cachedApiFetch("/api/status", { ttl: 30_000, staleTtl: 5 * 60_000 })
      .then((data) => { if (!cancelled) setStatus(data); })
      .catch((err) => { if (!cancelled) setError(err.message); });
    return () => { cancelled = true; };
  }, []);

  const healthy = status?.ok;

  return (
    <Page title="Status" eyebrow="Service health" lede="Live service health and incident history.">
      {error ? <Notice kind="error">{error}</Notice> : null}
      {status ? (
        <>
          <div className={`status-banner ${healthy ? "status-ok" : "status-down"}`}>
            {healthy ? <CheckCircle2 size={20} /> : <XCircle size={20} />}
            <span>{healthy ? "All systems operational" : "We're aware of an issue -- see below"}</span>
          </div>
          <div className="stat-strip">
            <article className="metric liquid-glass">
              <strong>{status.database_reachable ? "Online" : "Offline"}</strong>
              <span>Database</span>
            </article>
            <article className="metric liquid-glass">
              <strong>{status.active_incident_count}</strong>
              <span>Active incidents</span>
            </article>
          </div>
          <div className="section-head"><h2>Incident history</h2></div>
          {status.incidents?.length ? (
            <div className="incident-list">
              {status.incidents.map((incident) => (
                <article className={`incident-card ${incident.resolved ? "resolved" : "active"}`} key={incident.id}>
                  {severityIcon(incident.severity)}
                  <div>
                    <h3>{incident.title}</h3>
                    {incident.description ? <p>{incident.description}</p> : null}
                    <p className="incident-meta">
                      Started {new Date(incident.started_at).toLocaleString()}
                      {incident.resolved_at ? ` · Resolved ${new Date(incident.resolved_at).toLocaleString()}` : " · Ongoing"}
                    </p>
                  </div>
                </article>
              ))}
            </div>
          ) : (
            <EmptyState title="No incidents on record" hint="Nothing's gone wrong lately." />
          )}
          <p className="incident-meta">Last checked {new Date(status.server_time).toLocaleString()}.</p>
        </>
      ) : !error ? <p>Checking status…</p> : null}
    </Page>
  );
}
