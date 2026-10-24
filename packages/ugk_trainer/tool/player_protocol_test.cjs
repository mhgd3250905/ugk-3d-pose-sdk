#!/usr/bin/env node
// Execute the shipped player script against a bounded media/DOM fixture.
// This verifies protocol ordering, not Android WebView compositor behavior.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const assets = path.resolve(__dirname, '../assets/media_player');
const source = fs.readFileSync(path.join(assets, 'player.js'), 'utf8');
const html = fs.readFileSync(path.join(assets, 'player.html'), 'utf8');
const css = fs.readFileSync(path.join(assets, 'player.css'), 'utf8').replace(/\s/g, '');
const tick = () => new Promise(resolve => setImmediate(resolve));

function callbacks() {
  const entries = new Map();
  return {
    on(name, callback) {
      entries.set(name, [...(entries.get(name) || []), callback]);
    },
    fire(name) {
      for (const callback of entries.get(name) || []) callback();
    },
  };
}

function fixture({rvfc = true, readyState = 2} = {}) {
  const events = [];
  const videoEvents = callbacks();
  const documentEvents = callbacks();
  const windowEvents = callbacks();
  const frames = new Map();
  const raf = new Map();
  const draws = [];
  const encodings = [];
  let serial = 0;
  const attributes = new Map([['controls', '']]);
  const video = {
    style: {}, controls: true, muted: false, defaultMuted: false,
    paused: true, readyState, duration: 8, currentTime: 0,
    videoWidth: 720, videoHeight: 720,
    addEventListener: videoEvents.on,
    play() {
      this.paused = false;
      videoEvents.fire('play');
      videoEvents.fire('playing');
      return Promise.resolve();
    },
    pause() {
      if (this.paused) return;
      this.paused = true;
      videoEvents.fire('pause');
    },
    removeAttribute(name) {
      attributes.delete(name);
      if (name === 'controls') this.controls = false;
    },
    setAttribute(name, value) { attributes.set(name, value); },
    load() {},
    ...(rvfc ? {
      requestVideoFrameCallback(callback) {
        const id = ++serial;
        frames.set(id, callback);
        return id;
      },
      cancelVideoFrameCallback(id) { frames.delete(id); },
    } : {}),
  };
  const document = {
    hidden: false,
    querySelector: () => video,
    addEventListener: documentEvents.on,
    createElement(name) {
      assert.equal(name, 'canvas');
      return {
        width: 0, height: 0,
        getContext(kind) {
          assert.equal(kind, '2d');
          return {
            drawImage(target, ...rect) {
              assert.equal(target, video);
              draws.push({time: video.currentTime, rect});
            },
          };
        },
        toDataURL(type, quality) {
          encodings.push({type, quality, width: this.width, height: this.height});
          // The synthetic bytes expose which decoded frame was drawn, so a
          // cached first-frame image cannot pass the current-time assertion.
          return 'data:image/jpeg;base64,' + Buffer.from(JSON.stringify({
            time: draws.at(-1)?.time, width: this.width, height: this.height,
          })).toString('base64');
        },
      };
    },
  };
  const window = {
    DrillMediaHost: {postMessage: value => events.push(JSON.parse(value))},
    addEventListener: windowEvents.on,
  };
  const context = vm.createContext({
    document, window, parent: {},
    location: {search: '?id=fixture-a&src=/assets/fixture-a.mp4', origin: 'http://127.0.0.1:4321'},
    URLSearchParams,
    requestAnimationFrame(callback) { const id = ++serial; raf.set(id, callback); return id; },
    cancelAnimationFrame(id) { raf.delete(id); },
  });
  vm.runInContext(source, context, {filename: 'player.js'});
  const command = command => window.drillMediaCommand(command);
  const types = () => events.map(event => event.type);
  const flushRaf = () => {
    const queued = [...raf.values()];
    raf.clear();
    queued.forEach(callback => callback(0));
  };
  const frame = () => {
    const [id, callback] = [...frames.entries()][0] || [];
    assert(callback, 'A real video-frame callback must be scheduled');
    frames.delete(id);
    callback(0, {mediaTime: video.currentTime, presentedFrames: 1});
  };
  return {video, videoEvents, document, documentEvents, window, events, frames,
    raf, draws, encodings, command, types, flushRaf, frame};
}

const tests = [];
function test(name, action) { tests.push({name, action}); }

test('video is muted and native controls stay disabled', () => {
  const f = fixture();
  assert.equal(f.video.controls, false);
  assert.equal(f.video.muted, true);
  assert.equal(f.video.defaultMuted, true);
  assert(!/<video\b[^>]*\scontrols(?:\s|=|>)/i.test(html));
  assert(css.includes('video::-webkit-media-controls{display:none!important}'));
  assert(css.includes('video::-webkit-media-controls-start-playback-button'));
  assert(css.includes('video::-webkit-media-controls-overlay-play-button'));
});

test('metadata and loaded data do not announce the first visible frame', () => {
  const f = fixture();
  f.videoEvents.fire('loadedmetadata');
  f.videoEvents.fire('loadeddata');
  assert.deepEqual(f.types(), ['ready']);
  assert.equal(f.window.__drillMediaSnapshot().hasFrame, false);
});

test('rVFC must arrive after play before first-frame is emitted', async () => {
  const f = fixture();
  f.videoEvents.fire('loadedmetadata');
  f.command({type: 'play'});
  await tick();
  assert(!f.types().includes('first-frame'));
  assert.equal(f.frames.size, 1);
  f.frame();
  assert.equal(f.events.filter(event => event.type === 'first-frame').length, 1);
});

test('old WebViews require two paint callbacks after playing', async () => {
  const f = fixture({rvfc: false});
  f.videoEvents.fire('loadedmetadata');
  f.command({type: 'play'});
  await tick();
  assert(!f.types().includes('first-frame'));
  f.flushRaf();
  assert(!f.types().includes('first-frame'));
  f.flushRaf();
  assert.equal(f.events.filter(event => event.type === 'first-frame').length, 1);
});

test('capture-and-pause snapshots the current decoded frame and echoes captureId', async () => {
  const f = fixture();
  f.videoEvents.fire('loadedmetadata');
  f.command({type: 'play'});
  await tick();
  f.frame();
  f.video.currentTime = 4.25;
  f.command({type: 'capture-and-pause', captureId: 17});
  const event = f.events.find(event => event.type === 'frame' && event.captureId === 17);
  assert(event, 'Every accepted capture must reply using its request identity');
  assert.equal(f.video.paused, true);
  assert.equal(event.time, 4.25);
  const captured = JSON.parse(Buffer.from(event.frame, 'base64').toString());
  assert.equal(captured.time, 4.25, 'Must draw current video, not reuse an initial-frame cache');
  assert.deepEqual(f.encodings.at(-1), {type: 'image/jpeg', quality: .75, width: 480, height: 480});
});

test('a video without decoded data replies with null instead of inventing a snapshot', () => {
  const f = fixture({readyState: 0});
  f.command({type: 'capture-and-pause', captureId: 18});
  const event = f.events.find(event => event.type === 'frame' && event.captureId === 18);
  assert(event);
  assert.equal(event.frame, null);
  assert.equal(f.draws.length, 0);
});

test('pause invalidates a previously queued compositor callback', async () => {
  const f = fixture();
  f.videoEvents.fire('loadedmetadata');
  f.command({type: 'play'});
  await tick();
  const callback = [...f.frames.values()][0];
  f.command({type: 'pause'});
  callback(0, {mediaTime: 0});
  assert(!f.types().includes('first-frame'));
});

test('dispose blocks old frame callbacks and later capture messages', async () => {
  const f = fixture();
  f.videoEvents.fire('loadedmetadata');
  f.command({type: 'play'});
  await tick();
  const callback = [...f.frames.values()][0];
  f.command({type: 'dispose'});
  const count = f.events.length;
  callback(0, {mediaTime: 0});
  f.command({type: 'capture-and-pause', captureId: 19});
  f.videoEvents.fire('loadeddata');
  assert.equal(f.events.length, count);
});

(async () => {
  let failed = 0;
  for (const {name, action} of tests) {
    try { await action(); console.log(`ok - ${name}`); }
    catch (error) { failed++; console.error(`not ok - ${name}\n${error.stack}`); }
  }
  console.log(`${tests.length - failed}/${tests.length} player protocol tests passed`);
  process.exitCode = failed ? 1 : 0;
})();
