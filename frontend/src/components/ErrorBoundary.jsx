import { Component } from "react";
import { AlertTriangle, RefreshCw } from "lucide-react";

// Keeps one broken page (a malformed API row, a chunk that failed to load)
// from blanking the entire app. Without a boundary, any render error
// unmounts the whole React tree -- nav, player, everything -- and the only
// recovery is a manual reload. `resetKey` clears the error when it changes
// (the route, for the page boundary), so navigating away just works.
export class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error) {
    return { error };
  }

  componentDidCatch(error, info) {
    // eslint-disable-next-line no-console
    console.error("[nyxframe] render error", error, info?.componentStack);
    this.props.onError?.(error);
  }

  componentDidUpdate(prevProps) {
    if (this.state.error && prevProps.resetKey !== this.props.resetKey) {
      this.setState({ error: null });
    }
  }

  render() {
    if (!this.state.error) return this.props.children;
    if (this.props.fallback !== undefined) return this.props.fallback;
    return (
      <div className="page">
        <div className="empty-state" role="alert">
          <AlertTriangle size={24} />
          <h2>This page hit a problem</h2>
          <p className="empty-state-hint">Something went wrong while showing this view. The rest of the site still works.</p>
          <button type="button" className="button-link" onClick={() => this.setState({ error: null })}>
            <RefreshCw size={16} />Try again
          </button>
        </div>
      </div>
    );
  }
}
