import { useEffect, useRef, useState } from "react";
import { Music, VolumeX } from "lucide-react";
import { apiFetch } from "../api.js";

const MUTE_STORAGE_KEY = "nyxframe_bg_music_muted";
// BUGFIX 2026-09-14: was 0.35/0.06 -- confirmed live (real device test,
// nothing blocked, playback genuinely running at this volume) that this
// read as "basically silent" in practice once combined with a normal
// system volume and the source track's own moderate loudness (-26dB mean,
// confirmed via ffmpeg volumedetect against the actual stored file -- nice
// dynamic range for a full track, but quiet as *background* music at only
// 35% on top of that). Raised to something actually audible as ambient
// music; DUCK_VOLUME keeps roughly the same ~1:6 ratio to NORMAL_VOLUME as
// before, so ducking under video audio still fades to a faint bed rather
// than a full mute, just scaled up with it.
const NORMAL_VOLUME = 0.6;
const DUCK_VOLUME = 0.1;
const FADE_MS = 400;

// VideoPlayer.jsx dispatches this on every play/pause (native <video> and
// hls.js both funnel through the same onPlay/onPause handlers already
// wired there) so this component doesn't need any prop-drilled or context
// wiring through the whole route tree to know "is a video currently
// playing with sound anywhere on this page" -- it just listens globally.
const VIDEO_PLAYING_EVENT = "nyxframe:video-playing";

function shuffle(list) {
  const copy = list.slice();
  for (let i = copy.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}

// Requested feature: an admin-managed shuffled ambient soundtrack that
// plays while visitors browse, fading down (not fully muting -- keeps a
// faint bed under video audio, which reads as smoother than an abrupt cut)
// whenever a video with sound starts, and fading back once it stops.
//
// Every browser blocks UNMUTED autoplay outright -- there is no way to
// legitimately start audible audio before some real interaction, on any
// platform. But MUTED autoplay is allowed everywhere (same trick this
// site's own grid video previews already use), so playback now starts
// the instant tracks are known, muted, and the first interaction just
// flips audio.muted to false instead of calling play() for the first
// time -- previously play() itself was deferred until that first
// interaction, so "loads tracks but stays silent until you click
// something" read as "doesn't start playing" even though it was only
// ever a few hundred ms of unavoidable initial mute, not a stuck/broken
// player.
export function BackgroundMusicPlayer() {
  const audioRef = useRef(null);
  const queueRef = useRef([]);
  const duckedRef = useRef(false);
  const fadeTimerRef = useRef(null);
  const [tracks, setTracks] = useState([]);
  const [muted, setMuted] = useState(() => {
    try {
      return localStorage.getItem(MUTE_STORAGE_KEY) === "1";
    } catch (_error) {
      return false;
    }
  });
  const mutedRef = useRef(muted);
  mutedRef.current = muted;
  const [started, setStarted] = useState(false);
  const interactedRef = useRef(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const data = await apiFetch("/api/background-music");
        if (!cancelled) setTracks(data.tracks || []);
      } catch (_error) {
        // Ambient music is best-effort -- never surface an error toast for it.
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // Always points at the current render's playNext -- the one-time
  // interaction-listener effect below is registered on mount (empty deps,
  // so it never re-subscribes) and needs to call whatever playNext is
  // CURRENT at the moment a visitor actually interacts, not the one from
  // mount time closing over the still-empty initial `tracks` state.
  const playNextRef = useRef(() => {});

  function playNext() {
    const audio = audioRef.current;
    if (!audio) return;
    if (queueRef.current.length === 0) queueRef.current = shuffle(tracks);
    const next = queueRef.current.shift();
    if (!next) return;
    audio.src = next.url;
    audio.play().catch(() => {});
  }
  playNextRef.current = playNext;

  // Starts the instant tracks are known -- muted, which every browser
  // allows regardless of interaction (see the top-of-file doc comment).
  // Un-muting (not a fresh play() call) is all the first interaction has
  // to do, which is what actually makes this feel instant instead of
  // silent-until-you-click.
  useEffect(() => {
    if (started || tracks.length === 0) return;
    setStarted(true);
    // A visitor who explicitly turned this off last time (localStorage)
    // shouldn't have audio data downloading in the background at all --
    // wait for them to turn it back on via the button instead of
    // muted-autoplaying something they've already said they don't want.
    if (mutedRef.current) return;
    const audio = audioRef.current;
    if (!audio) return;
    audio.volume = NORMAL_VOLUME;
    audio.muted = true;
    playNext();
    if (interactedRef.current) audio.muted = false;
  }, [tracks, started]);

  // Separate from the effect above because interaction can happen before
  // OR after tracks finish loading -- either order has to end in "audible
  // once both have happened, unless the visitor has explicitly muted it."
  //
  // BUGFIX 2026-09-14: this used to only flip `audio.muted = false`, on
  // the assumption that the tracks-loaded effect's initial muted
  // `audio.play()` call had already succeeded (every browser is supposed
  // to allow muted autoplay unconditionally) and was just sitting there
  // silently. Confirmed live that assumption doesn't always hold -- that
  // play() call can still reject with NotAllowedError ("user didn't
  // interact with the document first") even muted, depending on the
  // browser/context. Nothing ever retried it afterward: onEnded can't
  // fire for audio that never started, so a rejected initial attempt left
  // the element permanently paused at currentTime 0 with no audio ever
  // audible, no matter how many times a visitor clicked around -- exactly
  // "loads tracks but never actually plays". Retrying play() here
  // unconditionally (a real user gesture has definitely happened by this
  // point) fixes both that case and is a harmless no-op if it was already
  // playing. Mirrors toggleMuted's own "turn it back on" logic below.
  useEffect(() => {
    const onInteract = () => {
      interactedRef.current = true;
      const audio = audioRef.current;
      if (!audio || mutedRef.current) return;
      audio.muted = false;
      if (audio.paused) {
        if (!audio.src) playNextRef.current(); else audio.play().catch(() => {});
      }
    };
    const events = ["pointerdown", "keydown", "touchstart"];
    events.forEach((event) => window.addEventListener(event, onInteract, { once: true, passive: true }));
    return () => events.forEach((event) => window.removeEventListener(event, onInteract));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Ducking: fades toward the target volume over FADE_MS instead of
  // snapping, which reads as a jarring volume jump rather than a smooth
  // "making room for the video" dip.
  function fadeTo(target) {
    const audio = audioRef.current;
    if (!audio) return;
    if (fadeTimerRef.current) clearInterval(fadeTimerRef.current);
    const steps = 12;
    const start = audio.volume;
    const delta = (target - start) / steps;
    let i = 0;
    fadeTimerRef.current = setInterval(() => {
      i += 1;
      audio.volume = Math.max(0, Math.min(1, start + delta * i));
      if (i >= steps) clearInterval(fadeTimerRef.current);
    }, FADE_MS / steps);
  }

  useEffect(() => {
    function onVideoPlaying(event) {
      duckedRef.current = Boolean(event.detail?.playing);
      if (!started || muted) return;
      fadeTo(duckedRef.current ? DUCK_VOLUME : NORMAL_VOLUME);
    }
    window.addEventListener(VIDEO_PLAYING_EVENT, onVideoPlaying);
    return () => window.removeEventListener(VIDEO_PLAYING_EVENT, onVideoPlaying);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [started, muted]);

  function toggleMuted() {
    setMuted((current) => {
      const next = !current;
      try { localStorage.setItem(MUTE_STORAGE_KEY, next ? "1" : "0"); } catch (_error) { /* private mode */ }
      const audio = audioRef.current;
      if (audio) {
        if (next) {
          audio.muted = true;
          audio.pause();
        } else if (started) {
          // audio.muted explicitly cleared here -- the interaction-based
          // auto-unmute (see the effects above) only fires while the
          // visitor's saved preference is already "on," so a visitor who
          // starts muted and then explicitly clicks this button to turn
          // it on would otherwise stay muted at the element level forever
          // even though the button now shows it as on.
          audio.muted = false;
          audio.volume = duckedRef.current ? DUCK_VOLUME : NORMAL_VOLUME;
          if (!audio.src) playNext(); else audio.play().catch(() => {});
        }
      }
      return next;
    });
  }

  if (tracks.length === 0) return null;

  return (
    <>
      <audio ref={audioRef} onEnded={playNext} style={{ display: "none" }} />
      <button
        type="button"
        className="bg-music-toggle liquid-glass"
        onClick={toggleMuted}
        aria-pressed={!muted}
        title={muted ? "Turn on background music" : "Turn off background music"}
      >
        {muted ? <VolumeX size={16} /> : <Music size={16} />}
      </button>
    </>
  );
}
