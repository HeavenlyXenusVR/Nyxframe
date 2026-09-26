// Minimal WebVTT parsing, shared by the two things the player loads as
// VTT: seek-preview sprite cues and auto-generated captions.
//
// Why parse it ourselves instead of handing the URL to a <track> element
// and letting the browser do it: a <track> whose src is on another origin
// (this app's frontend is served from GitHub Pages while the API lives on
// its own domain) only loads if the <video> carries crossorigin, and
// setting that attribute puts EVERY media request the element makes --
// playlist and segments included -- into CORS mode. One response missing
// a header then breaks playback outright rather than just the captions.
// Fetching the cues ourselves keeps a decorative feature from being able
// to take the video down with it.

function parseTimestamp(value) {
  // hh:mm:ss.mmm or mm:ss.mmm
  const match = /^(?:(\d+):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?$/.exec(value.trim());
  if (!match) return null;
  const [, hours, minutes, seconds, millis] = match;
  return (
    Number(hours || 0) * 3600 +
    Number(minutes) * 60 +
    Number(seconds) +
    Number((millis || "0").padEnd(3, "0")) / 1000
  );
}

// Returns [{ start, end, text }], ignoring anything it doesn't
// understand rather than throwing: a malformed cue should cost that one
// cue, not the whole track.
export function parseVtt(text) {
  if (typeof text !== "string" || !text.trim()) return [];
  const cues = [];
  // \r\n and lone \r both appear in the wild; normalise before splitting.
  const blocks = text.replace(/\r\n?/g, "\n").split(/\n{2,}/);
  for (const block of blocks) {
    const lines = block.split("\n").filter((line) => line.trim() !== "");
    if (!lines.length) continue;
    // A cue may be preceded by an optional identifier line, so the arrow
    // isn't necessarily on the first line of the block.
    const arrowIndex = lines.findIndex((line) => line.includes("-->"));
    if (arrowIndex < 0) continue;
    const [rawStart, rawEnd] = lines[arrowIndex].split("-->");
    if (!rawStart || !rawEnd) continue;
    const start = parseTimestamp(rawStart);
    // Cue settings (align, position, ...) trail the end timestamp.
    const end = parseTimestamp(rawEnd.trim().split(/\s+/)[0]);
    if (start === null || end === null) continue;
    const payload = lines.slice(arrowIndex + 1).join("\n").trim();
    if (!payload) continue;
    cues.push({ start, end, text: payload });
  }
  return cues;
}

// Turns a sprite VTT (whose cue payload is `sprite.jpg#xywh=x,y,w,h`)
// into something the scrubber can look up by time. Returns null when the
// document has no usable cues, so a caller can cleanly fall back to a
// time-only tooltip.
export function parseSpriteVtt(text, sheetUrl) {
  const cues = parseVtt(text)
    .map((cue) => {
      const match = /#xywh=(-?\d+),(-?\d+),(\d+),(\d+)/.exec(cue.text);
      if (!match) return null;
      return {
        start: cue.start,
        end: cue.end,
        x: Number(match[1]),
        y: Number(match[2]),
        width: Number(match[3]),
        height: Number(match[4]),
      };
    })
    .filter(Boolean);
  if (!cues.length) return null;
  return { sheetUrl, cues };
}

// Binary search rather than a linear scan: this runs on every mousemove
// across the seek bar, and a sprite can carry a hundred cues.
export function spriteTileAt(sprite, time) {
  if (!sprite || !sprite.cues.length) return null;
  const { cues } = sprite;
  let low = 0;
  let high = cues.length - 1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (time < cues[mid].start) high = mid - 1;
    else if (time >= cues[mid].end) low = mid + 1;
    else return cues[mid];
  }
  // Past the last cue (or in a gap): the nearest neighbour is a better
  // preview than no preview at all.
  return cues[Math.min(Math.max(low, 0), cues.length - 1)];
}
