import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Clipboard, FileImage, FileVideo, RefreshCw, Trash2, Upload, WandSparkles } from "lucide-react";
import { apiFetch, clearApiCache, postClientDiagnostic, readToken, resolveApiUrl } from "../api.js";
import { MAX_UPLOAD_BYTES } from "../config.js";
import { addPendingUploadJob } from "../uploadJobs.js";
import { ChipRow, Page, RequireLogin, Segmented } from "../components/ui.jsx";
import { formatBytes } from "../utils/format.js";

const SUBCATEGORY_SLOT_COUNT = 3;
const EDGE_SAFE_UPLOAD_BYTES = 80 * 1024 * 1024;
const DEFAULT_CHUNK_BYTES = 20 * 1024 * 1024;
// Uniform ceiling for every upload-related request (init/chunk/finish/direct
// <=80MB/analyze) -- finalize_upload does real synchronous work server-side
// (fast-start remux, full-file sha256, up to a 30s AI vision call, disk
// save), and xhrJson previously had NO timeout at all, so a truly stalled
// connection would hang forever with no error surfaced to the user.
const UPLOAD_TIMEOUT_MS = 120_000;

// What each subcategory slot usually holds -- the labels and placeholders
// the old six-field grid used, kept as the one-row version's guidance.
const SUBCATEGORY_SLOTS = [
  { label: "Series or group", placeholder: "e.g. Final Fantasy" },
  { label: "Character or subject", placeholder: "e.g. Cloud Strife" },
  { label: "Variant or context", placeholder: "e.g. Advent Children" },
];

const VISIBILITY_OPTIONS = [
  ["public", "Public"],
  ["unlisted", "Unlisted"],
  ["private", "Private"],
];

const VISIBILITY_HINTS = {
  public: "Anyone can find it in Discover, search and your profile.",
  unlisted: "Only people with the link can see it. Hidden from Discover and search.",
  private: "Only you can see it.",
};

const OPTION_TOGGLES = [
  { key: "auto_ai", label: "AI metadata", hint: "After upload, fill in any title, category or tags you left blank." },
  { key: "is_adult", label: "18+", hint: "Only shown to viewers who have verified their age." },
  { key: "comments_enabled", label: "Comments", hint: "Let people comment on this post." },
  { key: "downloads_enabled", label: "Downloads", hint: "Show the download button on this post." },
  { key: "check_site_duplicates", label: "Check the whole site for duplicates", hint: "Warn if a similar post exists anywhere on Nyxframe, not just in your uploads." },
];

function blankSubcategorySlots() {
  return Array.from({ length: SUBCATEGORY_SLOT_COUNT }, () => "");
}

function sameName(a, b) {
  return String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase();
}

function findCategory(categories, text) {
  if (!String(text || "").trim()) return null;
  return (categories || []).find((category) => sameName(category.name, text)) || null;
}

function subcategoriesOf(category) {
  return category?.subcategories || category?.children || [];
}

// Category and subcategories are single type-or-pick fields now: a name that
// matches an existing entry is sent as its id, anything else as a new name to
// create -- the same two request shapes the old select + "New ..." input
// pairs produced, without making the uploader choose between two fields.
function resolvePlacement(categories, categoryText, subcategoryTexts) {
  const category = findCategory(categories, categoryText);
  const existingSubs = subcategoriesOf(category);
  const subcategoryIds = [];
  const subcategoryNames = [];
  normalizeSlots(subcategoryTexts).forEach((text) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    const match = existingSubs.find((sub) => sameName(sub.name, trimmed));
    if (match) subcategoryIds.push(String(match.id));
    else subcategoryNames.push(trimmed);
  });
  return {
    categoryId: category ? String(category.id) : "",
    categoryName: category ? "" : String(categoryText || "").trim(),
    subcategoryIds,
    subcategoryNames,
  };
}

function isAcceptedFile(file) {
  return Boolean(file && (file.type.startsWith("image/") || file.type.startsWith("video/")));
}

function formatDuration(seconds) {
  const total = Math.round(Number(seconds) || 0);
  const minutes = Math.floor(total / 60);
  return `${minutes}:${String(total % 60).padStart(2, "0")}`;
}

function parseTags(text) {
  return String(text || "").split(",").map((tag) => tag.trim()).filter(Boolean);
}

function normalizeSlots(values) {
  const slots = Array.isArray(values) ? values.slice(0, SUBCATEGORY_SLOT_COUNT) : [];
  while (slots.length < SUBCATEGORY_SLOT_COUNT) slots.push("");
  return slots.map((value) => String(value || ""));
}

function xhrJson(url, { method = "POST", body, contentType, onProgress, timeoutMs = UPLOAD_TIMEOUT_MS } = {}) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const token = readToken();
    xhr.open(method, url, true);
    if (token) xhr.setRequestHeader("Authorization", `Bearer ${token}`);
    xhr.setRequestHeader("Accept", "application/json");
    if (contentType) xhr.setRequestHeader("Content-Type", contentType);
    xhr.withCredentials = true;
    xhr.timeout = timeoutMs;
    if (onProgress) xhr.upload.addEventListener("progress", onProgress);
    xhr.addEventListener("load", () => {
      let payload = null;
      try { payload = xhr.responseText ? JSON.parse(xhr.responseText) : null; } catch { /* handled below */ }
      if (xhr.status >= 200 && xhr.status < 300) return resolve(payload);
      const detail = payload?.detail;
      reject(new Error(detail ? (Array.isArray(detail) ? detail.map((item) => item?.msg || item).join("; ") : String(detail)) : `Upload failed (${xhr.status})`));
    });
    xhr.addEventListener("error", () => reject(new Error("Network error during upload.")));
    xhr.addEventListener("abort", () => reject(new Error("Upload cancelled.")));
    xhr.addEventListener("timeout", () => reject(new Error("Request timed out. Please try again.")));
    xhr.send(body);
  });
}

export function UploadPage({ ctx }) {
  const navigate = useNavigate();
  const [form, setForm] = useState({
    file: null,
    title: "",
    description: "",
    source_url: "",
    category: "",
    subcategories: blankSubcategorySlots(),
    tags: "",
    is_adult: false,
    visibility: "public",
    comments_enabled: true,
    downloads_enabled: true,
    pinned: false,
    auto_ai: true,
    publish_at: "",
    check_site_duplicates: true,
  });
  const [preview, setPreview] = useState("");
  const [mediaInfo, setMediaInfo] = useState(null); // { width, height, duration }
  const [busy, setBusy] = useState(false);
  const [analyzing, setAnalyzing] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0); // 0–100
  const [dragActive, setDragActive] = useState(false);
  const [analysis, setAnalysis] = useState(null);
  const [duplicates, setDuplicates] = useState([]);
  const dragDepth = useRef(0);

  useEffect(() => {
    setMediaInfo(null);
    if (!form.file) {
      setPreview("");
      return undefined;
    }
    const url = URL.createObjectURL(form.file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [form.file]);

  useEffect(() => {
    setDuplicates([]);
    setAnalysis(null);
  }, [form.file]);

  // Paste an image straight from the clipboard (a screenshot, a copied
  // image) -- but never hijack a paste into a text field.
  useEffect(() => {
    function onPaste(event) {
      const target = event.target;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)) return;
      const file = [...(event.clipboardData?.files || [])].find(isAcceptedFile);
      if (!file) return;
      event.preventDefault();
      pickFile(file);
    }
    window.addEventListener("paste", onPaste);
    return () => window.removeEventListener("paste", onPaste);
  });

  if (!ctx.user) return <RequireLogin />;

  function pickFile(file) {
    if (!file) return;
    if (!isAcceptedFile(file)) {
      ctx.showToast("Only image and video files can be uploaded.", "error");
      return;
    }
    update("file", file);
  }

  // The whole page is a drop target. dragenter/dragleave fire for every
  // child element crossed, so count depth instead of trusting relatedTarget.
  function handleDragEnter(event) {
    if (![...(event.dataTransfer?.types || [])].includes("Files")) return;
    event.preventDefault();
    dragDepth.current += 1;
    setDragActive(true);
  }

  function handleDragOver(event) {
    if (![...(event.dataTransfer?.types || [])].includes("Files")) return;
    event.preventDefault();
  }

  function handleDragLeave(event) {
    if (![...(event.dataTransfer?.types || [])].includes("Files")) return;
    dragDepth.current = Math.max(0, dragDepth.current - 1);
    if (!dragDepth.current) setDragActive(false);
  }

  function handleDrop(event) {
    event.preventDefault();
    dragDepth.current = 0;
    setDragActive(false);
    pickFile(event.dataTransfer?.files?.[0]);
  }

  function update(key, value) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  function updateSubcategory(index, value) {
    setForm((current) => {
      const next = normalizeSlots(current.subcategories);
      next[index] = value;
      return { ...current, subcategories: next };
    });
  }

  function removeFile() {
    update("file", null);
    setUploadProgress(0);
  }

  async function analyze() {
    if (!form.file) return;
    // Analyze always sends the file as one plain multipart request (unlike
    // the real upload below, which switches to the chunked path above this
    // same threshold) -- a large enough picked file makes that single
    // request itself exceed this deployment's Cloudflare edge body-size cap
    // and 413s with a raw Cloudflare HTML error page, not a real API error
    // (reported live from a large wallpaper image). Analyze is a pure
    // convenience preview -- auto_ai already runs the same analysis
    // server-side during the real upload regardless -- so it's fine to just
    // decline up front here rather than build a second chunking path for a
    // pre-submit preview feature.
    if (form.file.size > EDGE_SAFE_UPLOAD_BYTES) {
      ctx.showToast("This file is too large to analyze here — go ahead and upload it directly; AI metadata still runs automatically.", "info");
      return;
    }
    setBusy(true);
    setAnalyzing(true);
    try {
      const body = new FormData();
      body.set("file", form.file);
      body.set("title", form.title);
      body.set("description", form.description);
      if (form.source_url.trim()) body.set("source_url", form.source_url.trim());
      body.set("tags", form.tags);
      // AI vision analysis can legitimately take up to ai_timeout_seconds+10 on the
      // backend (default 55s) before falling back to local heuristics, well past the
      // default 12s apiFetch timeout — use a longer timeout so real analyses don't abort.
      const data = await apiFetch("/api/media/analyze", { method: "POST", body, timeoutMs: UPLOAD_TIMEOUT_MS });
      setAnalysis(data.analysis);
      setDuplicates(data.possible_duplicates || []);
      // Only fills gaps -- anything the uploader already typed wins.
      setForm((current) => ({
        ...current,
        title: current.title || data.analysis?.title || "",
        category: current.category || data.analysis?.category_name || "",
        subcategories: normalizeSlots(current.subcategories).map((value, index) => {
          if (value) return value;
          return String(data.analysis?.subcategory_names?.[index] || "");
        }),
        tags: current.tags || (data.analysis?.tags || []).join(", "),
        is_adult: current.is_adult || Boolean(data.analysis?.is_adult),
      }));
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
      setAnalyzing(false);
    }
  }

  async function submit(event) {
    event.preventDefault();
    if (!form.file) return ctx.showToast("Choose a file first.", "error");
    if (form.file.size > MAX_UPLOAD_BYTES) return ctx.showToast(`This file is over the ${formatBytes(MAX_UPLOAD_BYTES)} upload limit.`, "error");
    if (duplicates.length) {
      const proceed = window.confirm(
        `This looks similar to ${duplicates.length} post${duplicates.length === 1 ? "" : "s"} already in your library. Upload anyway?`,
      );
      if (!proceed) return;
    }
    setBusy(true);
    setUploadProgress(0);
    const uploadT0 = performance.now();
    let uploadMethod = "direct";
    let chunkCount = 0;
    const reportUploadDiagnostic = (outcome, errorMessage) => postClientDiagnostic("/api/media/upload/diagnostics", {
      outcome,
      method: uploadMethod,
      duration_ms: Math.round(performance.now() - uploadT0),
      bytes: form.file.size,
      chunk_count: chunkCount || undefined,
      retry_count: 0, // no chunk-retry logic exists yet -- see xhrJson's single-attempt send
      error_message: errorMessage,
    });
    try {
      const body = new FormData();
      if (form.file) body.set("file", form.file);
      body.set("title", form.title);
      body.set("description", form.description);
      if (form.source_url.trim()) body.set("source_url", form.source_url.trim());
      const placement = resolvePlacement(ctx.lookups.categories, form.category, form.subcategories);
      body.set("category_id", placement.categoryId);
      body.set("category_name", placement.categoryName);
      body.set("subcategory_id", placement.subcategoryIds[0] || "");
      body.set("subcategory_name", placement.subcategoryNames[0] || "");
      body.set("subcategory_ids_json", JSON.stringify(placement.subcategoryIds));
      body.set("subcategory_names_json", JSON.stringify(placement.subcategoryNames));
      body.set("tags", form.tags);
      body.set("is_adult", String(form.is_adult));
      body.set("visibility", form.visibility);
      body.set("comments_enabled", String(form.comments_enabled));
      body.set("downloads_enabled", String(form.downloads_enabled));
      body.set("pinned", String(form.pinned));
      body.set("auto_ai", String(form.auto_ai));
      body.set("check_site_duplicates", String(form.check_site_duplicates));
      if (form.publish_at) body.set("publish_at", new Date(form.publish_at).toISOString());

      let data;
      if (form.file.size <= EDGE_SAFE_UPLOAD_BYTES) {
        const url = await resolveApiUrl("/api/media");
        data = await xhrJson(url, {
          body,
          onProgress: (progressEvent) => {
            if (progressEvent.lengthComputable) setUploadProgress(Math.round((progressEvent.loaded / progressEvent.total) * 100));
          },
        });
      } else {
        uploadMethod = "chunked";
        const init = await apiFetch("/api/media/upload/init", {
          method: "POST",
          timeoutMs: UPLOAD_TIMEOUT_MS,
          body: JSON.stringify({ total_size: form.file.size, filename: form.file.name }),
        });
        const chunkSize = Number(init.chunk_size) > 0 ? Number(init.chunk_size) : DEFAULT_CHUNK_BYTES;
        const initUrl = await resolveApiUrl("/api/media/upload/chunk");
        let uploaded = 0;
        for (let index = 0; uploaded < form.file.size; index += 1) {
          const chunk = form.file.slice(uploaded, Math.min(uploaded + chunkSize, form.file.size));
          await xhrJson(`${initUrl}?session_id=${encodeURIComponent(init.session_id)}&index=${index}`, {
            body: chunk,
            contentType: "application/octet-stream",
            onProgress: (progressEvent) => {
              const chunkLoaded = progressEvent.lengthComputable ? progressEvent.loaded : 0;
              setUploadProgress(Math.round(((uploaded + chunkLoaded) / form.file.size) * 100));
            },
          });
          uploaded += chunk.size;
          chunkCount += 1;
          setUploadProgress(Math.round((uploaded / form.file.size) * 100));
        }
        const metadata = Object.fromEntries([...body.entries()].filter(([key]) => key !== "file"));
        data = await apiFetch("/api/media/upload/finish", {
          method: "POST",
          // This request itself only runs the fast dry-run synchronously
          // (magic-byte sniff of the already-assembled file, form-field
          // validation) -- the slow part (fast-start remux, full-file
          // sha256, up to a 30s AI vision call, disk save) now happens in a
          // background thread server-side, so a real response normally
          // comes back in well under a second. UPLOAD_TIMEOUT_MS here is
          // just the shared ceiling for consistency with the other
          // upload-related requests, not because this one needs it.
          timeoutMs: UPLOAD_TIMEOUT_MS,
          body: JSON.stringify({
            ...metadata,
            session_id: init.session_id,
            total_size: form.file.size,
          }),
        });
      }

      if (data.status === "processing") {
        // Chunk upload finished and the fast dry-run (file type, visibility,
        // publish date, title/category unless AI auto-fill covers them)
        // passed -- the slow part (remux/hash/AI/save) is now running in a
        // background thread server-side. No reason to keep the uploader
        // sitting on this page for that: hand off to Shell's job poller
        // (survives navigation/reload since it's localStorage-backed) and
        // leave immediately.
        addPendingUploadJob({ jobId: data.job_id, filename: form.file.name });
        ctx.showToast("Upload queued — processing in the background. We'll let you know when it's ready.", "info");
        // "success" here means the upload itself (the part this page and its
        // timing actually cover) went through -- the background finish job's
        // own outcome is separately covered by routes.lua's "upload"/
        // "chunked" telemetry.record call once it completes.
        reportUploadDiagnostic("success");
        navigate("/profile");
        return;
      }

      clearApiCache();
      ctx.refreshLookups();
      if (!duplicates.length && data.possible_duplicates?.length) {
        ctx.showToast(
          `Uploaded — heads up, ${data.possible_duplicates.length} similar post${data.possible_duplicates.length === 1 ? "" : "s"} already exist in your library.`,
          "info",
        );
      } else if (data.possible_site_duplicates?.length) {
        ctx.showToast(
          `Uploaded — heads up, ${data.possible_site_duplicates.length} similar post${data.possible_site_duplicates.length === 1 ? "" : "s"} already exist elsewhere on the site.`,
          "info",
        );
      } else {
        ctx.showToast("Upload saved.", "success");
      }
      reportUploadDiagnostic("success");
      navigate(`/media/${data.media.id}`);
    } catch (error) {
      reportUploadDiagnostic("error", String(error.message || "").slice(0, 300));
      ctx.showToast(error.message, "error");
      setUploadProgress(0);
    } finally {
      setBusy(false);
    }
  }

  const categories = ctx.lookups.categories || [];
  const matchedCategory = findCategory(categories, form.category);
  const existingSubcategories = subcategoriesOf(matchedCategory);
  const isVideo = form.file?.type?.startsWith("video/");
  const tooBig = Boolean(form.file && form.file.size > MAX_UPLOAD_BYTES);
  const tooBigToAnalyze = Boolean(form.file && form.file.size > EDGE_SAFE_UPLOAD_BYTES);
  const tagList = parseTags(form.tags);
  const analysisChips = analysis
    ? [analysis.media_kind, analysis.source, analysis.category_name, ...(analysis.subcategory_names || []), ...((analysis.tags || []).slice(0, 4))].filter(Boolean)
    : [];
  const uploading = busy && !analyzing;
  const fileFacts = form.file
    ? [
      isVideo ? "Video" : "Image",
      formatBytes(form.file.size),
      mediaInfo?.width ? `${mediaInfo.width}×${mediaInfo.height}` : "",
      mediaInfo?.duration ? formatDuration(mediaInfo.duration) : "",
    ].filter(Boolean)
    : [];
  let status = "Choose a file to get started.";
  if (uploading) status = uploadProgress >= 100 ? "Finishing up…" : `Uploading… ${uploadProgress}%`;
  else if (analyzing) status = "Analyzing with AI…";
  else if (tooBig) status = `Over the ${formatBytes(MAX_UPLOAD_BYTES)} limit — choose a smaller file.`;
  else if (form.file && !form.title.trim() && !form.auto_ai) status = "Add a title, or turn on AI metadata to fill it in.";
  else if (form.file) status = `Ready · ${form.file.name}`;

  return (
    <Page
      title="Upload"
      eyebrow="Create"
      lede="Add an image or video to the gallery. Drop a file anywhere on this page, or paste one from your clipboard."
    >
      <form
        className={`upload-page${dragActive ? " is-dragging" : ""}`}
        onSubmit={submit}
        onDragEnter={handleDragEnter}
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        onDrop={handleDrop}
      >
        {dragActive ? (
          <div className="upload-drop-overlay" aria-hidden="true">
            <Upload size={36} />
            <strong>Drop to add this file</strong>
          </div>
        ) : null}

        <aside className="upload-media">
          {!form.file ? (
            <label className="upload-dropzone">
              <input type="file" accept="image/*,video/*" onChange={(event) => { pickFile(event.target.files?.[0]); event.target.value = ""; }} />
              <span className="upload-dropzone-icon"><Upload size={28} /></span>
              <strong>Drop an image or video</strong>
              <span className="upload-dropzone-cta">Choose a file</span>
              <small>Images, GIFs and videos · up to {formatBytes(MAX_UPLOAD_BYTES)}</small>
              <small className="upload-dropzone-paste"><Clipboard size={13} />You can also paste an image</small>
            </label>
          ) : (
            <div className="upload-file-card">
              <div className="upload-preview">
                {!preview ? null : isVideo ? (
                  <video
                    src={preview}
                    controls
                    muted
                    playsInline
                    onLoadedMetadata={(event) => setMediaInfo({ width: event.currentTarget.videoWidth, height: event.currentTarget.videoHeight, duration: event.currentTarget.duration })}
                  />
                ) : (
                  <img
                    src={preview}
                    alt="Preview of the file you picked"
                    onLoad={(event) => setMediaInfo({ width: event.currentTarget.naturalWidth, height: event.currentTarget.naturalHeight })}
                  />
                )}
              </div>
              <div className="upload-file-meta">
                {isVideo ? <FileVideo size={18} /> : <FileImage size={18} />}
                <div>
                  <strong title={form.file.name}>{form.file.name}</strong>
                  <span>{fileFacts.join(" · ")}</span>
                </div>
              </div>
              {tooBig ? (
                <p className="upload-file-error" role="alert">
                  This file is {formatBytes(form.file.size)}, over the {formatBytes(MAX_UPLOAD_BYTES)} upload limit.
                </p>
              ) : null}
              <div className="upload-file-actions">
                <label className={`button-link${uploading ? " is-disabled" : ""}`}>
                  <RefreshCw size={15} />Replace
                  <input type="file" accept="image/*,video/*" disabled={uploading} onChange={(event) => { pickFile(event.target.files?.[0]); event.target.value = ""; }} />
                </label>
                <button type="button" onClick={removeFile} disabled={uploading}><Trash2 size={15} />Remove</button>
              </div>
            </div>
          )}

          <section className="upload-ai" aria-label="AI auto-fill">
            <div className="upload-ai-copy">
              <h3><WandSparkles size={16} />AI auto-fill</h3>
              <p>Suggests a title, category, subcategories and tags from the file. Anything you&rsquo;ve already typed is kept.</p>
            </div>
            <button
              type="button"
              onClick={analyze}
              disabled={busy || !form.file || tooBigToAnalyze}
              title={tooBigToAnalyze ? "Too large to analyze here — upload directly instead; AI metadata still runs automatically." : undefined}
            ><WandSparkles size={16} />{analyzing ? "Analyzing…" : "Analyze with AI"}</button>
            {tooBigToAnalyze ? <p className="muted small">This file is too large to analyze before uploading. AI metadata still runs after upload if it&rsquo;s turned on.</p> : null}
            {analysis ? <ChipRow values={analysisChips} /> : null}
            {analysis?.reason ? <p className="muted small">{analysis.reason}</p> : null}
          </section>

          {duplicates.length ? (
            <div className="upload-duplicate-warning" role="alert">
              <p className="small">
                Looks similar to {duplicates.length} post{duplicates.length === 1 ? "" : "s"} already in your library:
              </p>
              <div className="upload-duplicate-thumbs">
                {duplicates.map((dup) => (
                  <Link key={dup.id} to={`/media/${dup.id}`} target="_blank" title={dup.title || `Post #${dup.id}`}>
                    <img src={dup.thumb_url} alt={dup.title || `Post #${dup.id}`} />
                  </Link>
                ))}
              </div>
            </div>
          ) : null}
        </aside>

        <div className="upload-form">
          <section className="upload-section">
            <h2>Details</h2>
            <label className="field">
              <span className="field-head">Title<small aria-hidden="true">{form.title.length}/160</small></span>
              <input value={form.title} onChange={(event) => update("title", event.target.value)} required={!form.auto_ai} maxLength={160} placeholder={form.auto_ai ? "Leave blank to let AI name it" : "Give it a name"} />
            </label>
            <label className="field">
              <span className="field-head">Description<small aria-hidden="true">{form.description.length}/2000</small></span>
              <textarea value={form.description} onChange={(event) => update("description", event.target.value)} rows={4} maxLength={2000} placeholder="Optional" />
            </label>
            <label className="field">
              <span className="field-head">Original source</span>
              <input value={form.source_url} onChange={(event) => update("source_url", event.target.value)} type="url" inputMode="url" maxLength={500} placeholder="https://… where you got this (optional)" />
            </label>
            <label className="field">
              <span>Tags</span>
              <input value={form.tags} onChange={(event) => update("tags", event.target.value)} placeholder="cloud, aria, wallpaper" />
              <small className="field-hint">Separate tags with commas.</small>
            </label>
            {tagList.length ? <ChipRow values={tagList.map((tag) => `#${tag}`)} /> : null}
          </section>

          <section className="upload-section">
            <h2>Where it goes</h2>
            <label className="field">
              <span className="field-head">
                Category
                {form.category.trim() ? <small className={`placement-badge ${matchedCategory ? "is-existing" : "is-new"}`}>{matchedCategory ? "Existing" : "New — created on upload"}</small> : null}
              </span>
              <input
                list="upload-category-options"
                value={form.category}
                onChange={(event) => update("category", event.target.value)}
                placeholder={categories.length ? `e.g. ${categories[0].name}` : "Type a category"}
                autoComplete="off"
              />
              <datalist id="upload-category-options">
                {categories.map((category) => <option key={category.id} value={category.name} />)}
              </datalist>
              <small className="field-hint">Pick an existing category or type a new one.</small>
            </label>
            <div className="upload-subcategories">
              {SUBCATEGORY_SLOTS.map((slot, index) => {
                const text = normalizeSlots(form.subcategories)[index];
                const isExisting = existingSubcategories.some((sub) => sameName(sub.name, text));
                return (
                  <label className="field" key={slot.label}>
                    <span className="field-head">
                      {slot.label}
                      {text.trim() ? <small className={`placement-badge ${isExisting ? "is-existing" : "is-new"}`}>{isExisting ? "Existing" : "New"}</small> : null}
                    </span>
                    <input
                      list="upload-subcategory-options"
                      value={text}
                      onChange={(event) => updateSubcategory(index, event.target.value)}
                      placeholder={slot.placeholder}
                      autoComplete="off"
                    />
                  </label>
                );
              })}
              <datalist id="upload-subcategory-options">
                {existingSubcategories.map((sub) => <option key={sub.id} value={sub.name} />)}
              </datalist>
            </div>
            <small className="field-hint">Subcategories are optional. Up to three, from broad to specific.</small>
          </section>

          <section className="upload-section">
            <h2>Visibility &amp; options</h2>
            <div className="field">
              <span>Who can see it</span>
              <Segmented value={form.visibility} onChange={(value) => update("visibility", value)} options={VISIBILITY_OPTIONS} />
              <small className="field-hint">{VISIBILITY_HINTS[form.visibility]}</small>
            </div>
            <label className="field">
              <span>Schedule for later <small>(optional)</small></span>
              <input type="datetime-local" value={form.publish_at} onChange={(event) => update("publish_at", event.target.value)} />
              <small className="field-hint">{form.publish_at ? "It stays hidden until then." : "Leave empty to publish right away."}</small>
            </label>
            <div className="upload-toggles">
              {OPTION_TOGGLES.map((option) => (
                <label className="upload-toggle" key={option.key}>
                  <span>
                    <strong>{option.label}</strong>
                    <small id={`upload-hint-${option.key}`}>{option.hint}</small>
                  </span>
                  <input
                    type="checkbox"
                    role="switch"
                    aria-label={option.label}
                    aria-describedby={`upload-hint-${option.key}`}
                    checked={form[option.key]}
                    onChange={(event) => update(option.key, event.target.checked)}
                  />
                </label>
              ))}
            </div>
          </section>

          <div className="upload-actionbar">
            <div className="upload-status">
              <span className={tooBig ? "is-error" : ""}>{status}</span>
              {uploading && uploadProgress > 0 ? (
                <div className="upload-progress-track" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={uploadProgress} aria-label="Upload progress">
                  <div className="upload-progress-fill" style={{ width: `${uploadProgress}%` }} />
                </div>
              ) : null}
            </div>
            <button className="primary" type="submit" disabled={busy || !form.file || tooBig}><Upload size={16} />{uploading ? "Uploading" : "Upload"}</button>
          </div>
        </div>
      </form>
    </Page>
  );
}
