const assert = require('node:assert/strict');
const {createPackPlayer, trustedVideoUrl, vertexSource, fragmentSource} = require('../assets/pose_hub_player/player.js');

function fixture({webgl = true, rvfc = true, shaderFailure = null, linkFailure = false, compilerLog = 'synthetic compiler diagnostic'} = {}) {
  const listeners = new Map(), frames = new Map(), rafs = new Map(), events = [], calls = [];
  let sequence = 0;
  const video = {
    paused: true, readyState: 0, videoWidth: 720, videoHeight: 1440,
    currentTime: 2.375, muted: false, controls: true,
    addEventListener: (name, cb) => listeners.set(name, cb),
    removeEventListener: name => listeners.delete(name),
    removeAttribute: name => calls.push(['removeAttribute', name]),
    load: () => calls.push(['load']),
    play: async () => {video.paused = false; calls.push(['play']);},
    pause: () => {video.paused = true; calls.push(['pause']);},
    ...(rvfc ? {
      requestVideoFrameCallback: cb => {const id = ++sequence; frames.set(id, cb);return id;},
      cancelVideoFrameCallback: id => frames.delete(id),
    } : {}),
  };
  const gl = new Proxy({}, {get: (_, name) => {
    if (name === 'NO_ERROR') return 0;
    if (name === 'getError') return () => 0;
    if (name === 'createShader') return type => ({id: ++sequence, type});
    if (name === 'getShaderParameter') return shader => shader.type !== shaderFailure;
    if (name === 'getProgramParameter') return () => !linkFailure;
    if (name === 'getShaderInfoLog' || name === 'getProgramInfoLog') return () => compilerLog;
    if (name === 'getExtension') return () => ({loseContext: () => calls.push(['loseContext'])});
    if (String(name).startsWith('create')) return () => ({id: ++sequence});
    if (name === 'getAttribLocation' || name === 'getUniformLocation') return (...args) => {calls.push([name,...args]);return 0;};
    if (/^[A-Z_0-9]+$/.test(name)) return name;
    return (...args) => calls.push([name, ...args]);
  }});
  const env = {video, canvas:{width:0,height:0},gl:webgl ? gl : null, session:'session-test',
    emit:e=>events.push(e),requestAnimationFrame:cb=>{const id=++sequence;rafs.set(id,cb);return id;},
    cancelAnimationFrame:id=>rafs.delete(id)};
  const player = createPackPlayer(env);
  const flush = async () => {await Promise.resolve();await Promise.resolve();};
  const ready = () => {video.readyState=2;listeners.get('loadedmetadata')?.();};
  const next = list => {const entry=list.entries().next().value;assert.ok(entry,'frame requested');list.delete(entry[0]);entry[1]();};
  return {player,video,events,calls,frames,rafs,env,ready,flush,next};
}

const tests = [];
function test(name, fn) {tests.push([name,fn]);}
test('GLSL identifiers exclude reserved words and bind the video sampler by its declared name', () => {
  // This catches the observed regression; it is not a substitute for compiling
  // the shader in the actual target browser/driver.
  const reserved = new Set('asm class union enum typedef template this packed goto switch default inline noinline volatile public static extern external interface long short double half fixed unsigned superp input output hvec2 hvec3 hvec4 dvec2 dvec3 dvec4 fvec2 fvec3 fvec4 sampler1D sampler3D sampler1DShadow sampler2DShadow sampler2DRect sampler3DRect sampler2DRectShadow sizeof cast namespace using'.split(' '));
  for (const source of [vertexSource, fragmentSource]) {
    const declarations = source.matchAll(/\b(?:attribute|varying|uniform)\s+\w+\s+(\w+)/g);
    for (const match of declarations) assert.equal(reserved.has(match[1]), false, `${match[1]} is reserved`);
  }
  assert.match(fragmentSource, /uniform sampler2D uPackedVideo;/);
  assert.doesNotMatch(fragmentSource, /\bpacked\b/);
  const f=fixture();
  assert.ok(f.calls.some(c=>c[0]==='getUniformLocation' && c[2]==='uPackedVideo'));
});
test('shader and link failures retain their compiler stage and bounded diagnostic', async () => {
  for (const stage of ['VERTEX_SHADER', 'FRAGMENT_SHADER']) {
    const f=fixture({shaderFailure:stage,compilerLog:'  ERROR: illegal reserved identifier  '});
    assert.equal(f.events.at(-1).code,'shader_compile');
    assert.equal(f.events.at(-1).stage,stage === 'VERTEX_SHADER' ? 'vertex' : 'fragment');
    assert.equal(f.events.at(-1).detail,'ERROR: illegal reserved identifier');
    f.ready();f.player.command({type:'play'});await f.flush();
    assert.equal(f.video.paused,true);assert.equal(f.events.some(e=>e.type==='ready' || e.type==='first-frame'),false);
    assert.ok(f.calls.some(c=>c[0]==='deleteShader'));
  }
  const f=fixture({linkFailure:true,compilerLog:'x'.repeat(3000)});
  assert.equal(f.events.at(-1).code,'shader_link');assert.equal(f.events.at(-1).stage,'link');
  assert.equal(f.events.at(-1).detail.length,2048);
});
test('only same-origin plain MP4 URLs are accepted', () => {
  assert.equal(trustedVideoUrl('/__posehub_pack__/media/abs-A/video.mp4','https://sdk.example/assets/player.html'), 'https://sdk.example/__posehub_pack__/media/abs-A/video.mp4');
  for (const value of ['https://other.example/a.mp4','https://u:p@sdk.example/a.mp4','/a.mp4?token=x','/a.mp4#x','javascript:alert(1)','/cover.webp']) {
    assert.throws(()=>trustedVideoUrl(value,'https://sdk.example/assets/player.html'));
  }
});
test('metadata never announces a composed frame; source is muted and looped', () => {
  const f=fixture();f.ready();
  assert.equal(f.video.muted,true);assert.equal(f.video.defaultMuted,true);
  assert.equal(f.video.controls,false);assert.equal(f.video.loop,true);
  assert.equal(f.events.filter(e=>e.type==='ready').length,1);
  assert.equal(f.events.filter(e=>e.type==='first-frame').length,0);
  assert.equal(f.calls.filter(c=>c[0]==='texImage2D').length,0);
});
test('first-frame requires a successful GPU draw after play and rVFC', async () => {
  const f=fixture();f.ready();f.player.command({type:'play'});await f.flush();
  assert.equal(f.events.filter(e=>e.type==='first-frame').length,0);
  f.next(f.frames);
  assert.equal(f.calls.filter(c=>c[0]==='texImage2D').length,1);
  assert.equal(f.calls.filter(c=>c[0]==='drawArrays').length,1);
  assert.equal(f.env.canvas.width,720);assert.equal(f.env.canvas.height,720);
  assert.equal(f.events.filter(e=>e.type==='first-frame').length,1);
  f.next(f.frames);assert.equal(f.events.filter(e=>e.type==='first-frame').length,1);
  assert.match(fragmentSource,/y\+0\.5/);assert.match(fragmentSource,/rgb\*a,a/);
});
test('pause invalidates an already queued frame without announcing it', async () => {
  const f=fixture();f.ready();f.player.command({type:'play'});await f.flush();
  const pending=f.frames.values().next().value;
  f.player.command({type:'pause'});pending();
  assert.equal(f.video.paused,true);assert.equal(f.frames.size,0);
  assert.equal(f.events.some(e=>e.type==='first-frame'),false);
  assert.equal(f.calls.some(c=>c[0]==='drawArrays'),false);
});
test('older browsers wait two paint callbacks, and cancel them on pause', async () => {
  const f=fixture({rvfc:false});f.ready();f.player.command({type:'play'});await f.flush();
  f.next(f.rafs);assert.equal(f.events.some(e=>e.type==='first-frame'),false);
  f.next(f.rafs);assert.equal(f.events.filter(e=>e.type==='first-frame').length,1);
  f.player.command({type:'pause'});assert.equal(f.rafs.size,0);
});
test('hidden state pauses and resumes only the host-requested playback', async () => {
  const f=fixture();f.ready();f.player.command({type:'play'});await f.flush();
  f.player.command({type:'visible',value:false});assert.equal(f.video.paused,true);
  f.player.command({type:'visible',value:true});await f.flush();assert.equal(f.video.paused,false);
  f.player.command({type:'pause'});f.player.command({type:'visible',value:false});f.player.command({type:'visible',value:true});await f.flush();
  assert.equal(f.video.paused,true);
});
test('position is null before a composed frame, then uses decoder time', async () => {
  const f=fixture();f.ready();f.player.command({type:'position',requestId:1});
  assert.equal(f.events.at(-1).time,null);
  f.player.command({type:'play'});await f.flush();f.next(f.frames);
  f.player.command({type:'position',requestId:2});assert.equal(f.events.at(-1).time,2.375);
  assert.equal(f.events.at(-1).requestId,2);
});
test('dispose releases resources, source and callbacks and blocks later messages', async () => {
  const f=fixture();f.ready();f.player.command({type:'play'});await f.flush();
  const pending=f.frames.values().next().value;f.player.dispose();const n=f.events.length;
  pending();f.player.command({type:'play'});await f.flush();
  assert.equal(f.events.length,n);assert.equal(f.frames.size,0);assert.equal(f.video.paused,true);
  for (const command of ['deleteTexture','deleteBuffer','deleteProgram','loseContext','load']) assert.ok(f.calls.some(c=>c[0]===command),command);
});
test('WebGL unavailable and invalid packed dimensions are explicit errors', async () => {
  const f=fixture({webgl:false});assert.equal(f.events.at(-1).code,'webgl_unavailable');
  f.ready();f.player.command({type:'play'});await f.flush();assert.equal(f.video.paused,true);
  const bad=fixture();bad.video.videoHeight=720;bad.ready();assert.equal(bad.events.at(-1).code,'invalid_packed_dimensions');
});
(async()=>{for(const [name,fn] of tests){await fn();process.stdout.write(`ok - ${name}\n`);}process.stdout.write(`${tests.length}/${tests.length} pack player tests passed\n`);})().catch(error=>{process.stderr.write(`${error.stack}\n`);process.exitCode=1;});
