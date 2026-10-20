const params = new URLSearchParams(location.search);
const id = params.get('id');
const requestedPosterTime = Number(params.get('posterTime') || 0);
const video = document.querySelector('#video');
let active = params.get('active') !== 'false';
let disposed = false;
let playGeneration = 0;
let hasFrame = false;
let frameGeneration = 0;
let frameRequest = null;
let rafRequest = null;
let mediaReady = false;
let initialSeekPending = false;
let initialSeekStarted = false;
let posterTime = 0;
let pendingPlay = false;
// The host asked to play and hasn't asked to stop: survives the page being
// hidden (app in background / screen locked) so playback resumes on return.
let hostWantsPlay = false;
// iOS WebKit: autoplay without a gesture needs the *property* muted too.
video.muted = true;
video.defaultMuted = true;
const emit = type => {
  if (disposed) return;
  const event = {source:'drill-media', type, id, playing:!video.paused,
    time:video.currentTime, duration:Number.isFinite(video.duration)?video.duration:0};
  if (window.DrillMediaHost) window.DrillMediaHost.postMessage(JSON.stringify(event));
  else parent.postMessage(event, location.origin);
};
function cancelFirstFrame() {
  ++frameGeneration;
  if (frameRequest !== null) video.cancelVideoFrameCallback?.(frameRequest);
  if (rafRequest !== null) cancelAnimationFrame(rafRequest);
  frameRequest = rafRequest = null;
}
function revealFirstFrame(generation) {
  if (generation !== frameGeneration || hasFrame || disposed || !active ||
      document.hidden || video.paused || video.readyState < 2) return;
  hasFrame = true;
  // The video already renders opaquely underneath Flutter's poster. Only
  // the host fades that poster: starting a CSS fade here races the native
  // compositor and can reveal an empty/dim frame between the two fades.
  frameRequest = rafRequest = null;
  emit('first-frame');
}
function watchFirstFrame() {
  if (hasFrame || disposed || !active || document.hidden) return;
  cancelFirstFrame();
  const generation = frameGeneration;
  if (typeof video.requestVideoFrameCallback === 'function') {
    // Metadata and `play` do not prove a frame reached the compositor.
    frameRequest = video.requestVideoFrameCallback(() => {
      frameRequest = null;
      revealFirstFrame(generation);
    });
  }
}
function fallbackFirstFrame() {
  if (typeof video.requestVideoFrameCallback === 'function' || hasFrame ||
      disposed || !active || document.hidden || video.paused) return;
  cancelFirstFrame();
  const generation = frameGeneration;
  // Old WebViews: `playing` confirms available data; allow a paint between
  // two animation frames before retiring the host's opaque poster.
  rafRequest = requestAnimationFrame(() => {
    if (generation !== frameGeneration || disposed) return;
    rafRequest = requestAnimationFrame(() => revealFirstFrame(generation));
  });
}
function stop() { ++playGeneration; pendingPlay=false; cancelFirstFrame(); video.pause(); }
async function begin() {
  if (!active || disposed || document.hidden) return;
  if (!mediaReady) { pendingPlay=true; return; }
  pendingPlay=false;
  const generation = ++playGeneration;
  watchFirstFrame();
  try {
    await video.play();
    if (generation === playGeneration) fallbackFirstFrame();
  } catch (error) {
    if (generation === playGeneration) cancelFirstFrame();
    if (error.name !== 'AbortError' && generation === playGeneration && active && !disposed) emit('error');
  }
}
function signalReady() {
  if (disposed || mediaReady) return;
  initialSeekPending=false;
  mediaReady=true;
  emit('ready');
  if (pendingPlay) void begin();
}
video.addEventListener('loadedmetadata', () => {
  if (disposed || initialSeekStarted) return;
  initialSeekStarted=true;
  const duration = Number.isFinite(video.duration) ? video.duration : 0;
  posterTime = Number.isFinite(requestedPosterTime)
    ? Math.min(Math.max(0, requestedPosterTime), Math.max(0, duration - 1 / 30)) : 0;
  if (posterTime === 0) { signalReady(); return; }
  // Preserve the approved poster pose. Playback is not ready until the
  // initial seek completes, and the host still covers this prepared frame.
  initialSeekPending=true;
  try { video.currentTime=posterTime; } catch { emit('error'); }
});
video.addEventListener('playing', fallbackFirstFrame);
video.addEventListener('error', () => { cancelFirstFrame(); emit('error'); });
for (const type of ['play','pause']) video.addEventListener(type, () => {
  if (mediaReady) emit('state');
});
video.addEventListener('seeked', () => {
  if (initialSeekPending) { signalReady(); return; }
  if (mediaReady) emit('state');
});
window.drillMediaCommand = command => {
  if (disposed || !command) return;
  if (command.type === 'play') { hostWantsPlay=true; void begin(); }
  if (command.type === 'pause') { hostWantsPlay=false; stop(); }
  if (command.type === 'active') {
    active = command.value === true;
    if (!active) { hostWantsPlay=false; stop(); }
  }
  if (command.type === 'dispose') {
    hostWantsPlay=false; stop(); disposed=true; video.removeAttribute('src'); video.load();
  }
};
window.addEventListener('message', event => {
  if (event.origin === location.origin && event.source === parent &&
      event.data?.source === 'drill-media-host') window.drillMediaCommand(event.data.command);
});
// Hidden (background / locked) → pause; visible again → carry on if the host
// still wants the demo playing (it never re-sends `play` for an unchanged
// state, so without this the clip stayed frozen after unlocking).
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { stop(); return; }
  if (hostWantsPlay && active && !disposed) void begin();
});
window.addEventListener('pagehide', stop);
window.addEventListener('pageshow', () => {
  if (!document.hidden && hostWantsPlay && active && !disposed) void begin();
});
window.__drillMediaSnapshot = () => ({id,active,disposed,hasFrame,mediaReady,posterTime,playing:!video.paused,
  time:video.currentTime,duration:video.duration,readyState:video.readyState,
  error:video.error?.code || null});
// SmartFit clips are sf-<id>. HipLab clips were hip-<id> (lower case). Copied from 3D-Body@a83a0f4
// app/assets/drill_media/player.js. HipLab changes: this id rule; and
// (2026-10-17, round 1 #3) no `poster` attribute: the Flutter host covers the
// video with its poster until a composited frame is available. The video
// itself stays opaque, so the host is the only place that cross-fades.
// Native media controls are suppressed by CSS. Object-fit/position and a
// theme variant folder come from the host.
// (2026-10-17, iOS) muted set as a property for WebKit autoplay, no PiP /
// AirPlay / start-button overlay, and playback resumes after the page was
// hidden (app background, screen lock) while the host still wants it.
const fit = params.get('fit') === 'cover' ? 'cover' : 'contain';
const pos = /^\d{1,3}% \d{1,3}%$/.test(params.get('pos') || '') ? params.get('pos') : '50% 50%';
video.style.objectFit = fit;
video.style.objectPosition = pos;
// SmartFit 2026-10-19: `id` is a drill-pack id; the clip is the pack's
// demo.mp4 (assets/packs/<id>/, served at /packs/<id>/); variant=light plays
// the light-stage render demo-light.mp4 (2026-10-20, light theme).
// ugk_trainer 0.1.0: the host may name the clip itself (`src`, a same-origin
// absolute path such as /assets/packs/<id>/demo.mp4); without it the
// SmartFit layout ../packs/<id>/demo(-light).mp4 is used.
const clip = params.get('variant') === 'light' ? 'demo-light.mp4' : 'demo.mp4';
const src = params.get('src') || '';
if (src) {
  if (/^\/[A-Za-z0-9_\-./]+$/.test(src) && !src.includes('..') && !src.startsWith('//')) video.src = src;
  else emit('error');
} else if (!/^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/.test(id || '')) emit('error');
else { video.src=`../packs/${id}/${clip}`; }
