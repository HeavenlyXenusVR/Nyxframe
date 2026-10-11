import { useCallback, useEffect, useRef, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { Camera, X } from "lucide-react";
import { apiFetch } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { Page } from "../components/ui.jsx";
import { replaceMedia } from "../utils/media.js";

// Two independent entry points share this one page: a fresh image upload
// (the dedicated "Visual search" flow), or arriving with ?mediaId=123 from
// an existing post's "Find visually similar" link -- which reuses that
// post's already-stored perceptual hash via GET .../visual-similar instead
// of re-uploading/re-hashing the same bytes.
export function VisualSearchPage({ ctx }) {
  const [searchParams] = useSearchParams();
  const seedMediaId = searchParams.get("mediaId");

  const [preview, setPreview] = useState(null);
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [searched, setSearched] = useState(false);
  const fileInputRef = useRef(null);

  const handleItemUpdated = useCallback((item) => setItems((rows) => replaceMedia(rows, item)), []);

  const runSeedSearch = useCallback(async (mediaId) => {
    setLoading(true);
    setError("");
    setSearched(true);
    try {
      const data = await apiFetch(`/api/media/${mediaId}/visual-similar`);
      setItems(data.media || []);
    } catch (err) {
      setError(err.message);
      setItems([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (seedMediaId) {
      setPreview(null);
      runSeedSearch(seedMediaId);
    }
  }, [seedMediaId, runSeedSearch]);

  async function searchWithFile(file) {
    if (!file) return;
    setPreview(URL.createObjectURL(file));
    setLoading(true);
    setError("");
    setSearched(true);
    try {
      const body = new FormData();
      body.append("file", file);
      const data = await apiFetch("/api/search/visual", { method: "POST", body });
      setItems(data.media || []);
    } catch (err) {
      setError(err.message);
      setItems([]);
    } finally {
      setLoading(false);
    }
  }

  function onPick(event) {
    const file = event.target.files?.[0];
    if (file) searchWithFile(file);
  }

  function onDrop(event) {
    event.preventDefault();
    const file = event.dataTransfer.files?.[0];
    if (file) searchWithFile(file);
  }

  function reset() {
    setPreview(null);
    setItems([]);
    setError("");
    setSearched(false);
    if (fileInputRef.current) fileInputRef.current.value = "";
  }

  return (
    <Page title="Visual search" eyebrow="Reverse image search" lede="Find posts that look like a reference image.">
      {!seedMediaId ? (
        <div
          className="visual-search-drop"
          onDragOver={(event) => event.preventDefault()}
          onDrop={onDrop}
          onClick={() => fileInputRef.current?.click()}
          role="button"
          tabIndex={0}
        >
          {preview ? (
            <img src={preview} alt="Search reference" className="visual-search-preview" />
          ) : (
            <div className="visual-search-drop-hint">
              <Camera size={28} />
              <p>Drop an image here, or click to choose one</p>
            </div>
          )}
          <input ref={fileInputRef} type="file" accept="image/*" hidden onChange={onPick} />
          {preview ? (
            <button
              type="button"
              className="icon-button visual-search-clear"
              onClick={(event) => { event.stopPropagation(); reset(); }}
              aria-label="Clear"
            >
              <X size={14} />
            </button>
          ) : null}
        </div>
      ) : null}

      {error ? <p className="muted-copy">{error}</p> : null}
      {searched ? (
        <MediaGrid
          ctx={ctx}
          items={items}
          loading={loading}
          onItemUpdated={handleItemUpdated}
          emptyTitle="No visually similar posts found"
        />
      ) : null}
    </Page>
  );
}
