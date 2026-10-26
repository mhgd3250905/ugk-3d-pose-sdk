/* Original SDK RGB-over-alpha compositor. The packing math matches
 * shaders/packed_alpha.frag. Uses standard WebGL texture upload and rVFC;
 * no third-party player, CPU pixel readback, blur, keying or source rewrite. */
(function (global) {
  'use strict';
  const vertexSource = 'attribute vec2 p; varying vec2 uv; void main(){uv=vec2((p.x+1.0)*0.5,(1.0-p.y)*0.5);gl_Position=vec4(p,0.0,1.0);}';
  const fragmentSource = 'precision highp float; varying vec2 uv; uniform sampler2D uPackedVideo; uniform vec2 inputSize; void main(){vec2 halfTexel=vec2(0.5)/inputSize;float x=clamp(uv.x,halfTexel.x,1.0-halfTexel.x);float y=clamp(uv.y*0.5,halfTexel.y,0.5-halfTexel.y);vec3 rgb=texture2D(uPackedVideo,vec2(x,y)).rgb;float a=clamp(texture2D(uPackedVideo,vec2(x,y+0.5)).r,0.0,1.0);gl_FragColor=vec4(rgb*a,a);}';

  function failure(code, stage, detail) {
    return Object.assign(new Error(code), {code, stage, detail: String(detail || '').trim().slice(0, 2048)});
  }
  function diagnostic(error, fallback) {
    return {code: error.code || fallback, ...(error.stage ? {stage: error.stage} : {}),
      ...(error.detail ? {detail: error.detail} : {})};
  }

  function trustedVideoUrl(value, base) {
    const url = new URL(value, base);
    const origin = new URL(base).origin;
    if (!/^https?:$/.test(url.protocol) || url.origin !== origin || url.username || url.password || url.search || url.hash || !url.pathname.toLowerCase().endsWith('.mp4')) throw new Error('invalid_source');
    return url.href;
  }

  function createPackPlayer(env) {
    const video = env.video, canvas = env.canvas, gl = env.gl;
    let disposed = false, active = true, visible = true, wantsPlay = false;
    let hasFrame = false, generation = 0, rvfc = null, raf = null;
    let program = null, texture = null, buffer = null, usable = false;
    const handlers = [];
    const emit = (type, extra = {}) => {
      if (!disposed) env.emit({source: 'pose-hub-pack', session: env.session, type,
        playing: !video.paused, ...extra});
    };
    const listen = (type, callback) => { video.addEventListener(type, callback); handlers.push([type, callback]); };
    function shader(type, source) {
      const result = gl.createShader(type);
      gl.shaderSource(result, source); gl.compileShader(result);
      if (!gl.getShaderParameter(result, gl.COMPILE_STATUS)) {
        const error = failure('shader_compile', type === gl.VERTEX_SHADER ? 'vertex' : 'fragment', gl.getShaderInfoLog(result));
        gl.deleteShader(result); throw error;
      }
      return result;
    }
    function initialize() {
      if (!gl) throw new Error('webgl_unavailable');
      let vertex = null, fragment = null;
      try {
        vertex = shader(gl.VERTEX_SHADER, vertexSource); fragment = shader(gl.FRAGMENT_SHADER, fragmentSource);
        program = gl.createProgram(); gl.attachShader(program, vertex); gl.attachShader(program, fragment); gl.linkProgram(program);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw failure('shader_link', 'link', gl.getProgramInfoLog(program));
      } finally {
        if (vertex) gl.deleteShader(vertex); if (fragment) gl.deleteShader(fragment);
      }
      gl.useProgram(program);
      buffer = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.STATIC_DRAW);
      const position = gl.getAttribLocation(program, 'p'); gl.enableVertexAttribArray(position); gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
      texture = gl.createTexture(); gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      // Preserve BT.709 decoded RGB without an extra browser colour-space pass.
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false); gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
      gl.uniform1i(gl.getUniformLocation(program, 'uPackedVideo'), 0);
      gl.disable(gl.BLEND); gl.clearColor(0,0,0,0); usable = true;
    }
    function cancel() {
      generation++;
      if (rvfc !== null) video.cancelVideoFrameCallback?.(rvfc);
      if (raf !== null) env.cancelAnimationFrame(raf);
      rvfc = raf = null;
    }
    function canDraw() { return !disposed && active && visible && wantsPlay && !video.paused && video.readyState >= 2; }
    function draw() {
      if (!canDraw()) return false;
      const width = video.videoWidth, height = video.videoHeight;
      if (width <= 0 || height !== width * 2) { emit('error', {code: 'invalid_packed_dimensions'}); return false; }
      try {
        if (canvas.width !== width || canvas.height !== width) { canvas.width = width; canvas.height = width; }
        gl.viewport(0,0,width,width); gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);
        gl.uniform2f(gl.getUniformLocation(program, 'inputSize'), width, height);
        gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLE_STRIP,0,4);
        if (gl.getError() !== gl.NO_ERROR) throw new Error('webgl_draw');
        if (!hasFrame) { hasFrame = true; emit('first-frame'); }
        return true;
      } catch (_) { wantsPlay = false; video.pause(); cancel(); emit('error', {code: 'composition_failed'}); return false; }
    }
    function schedule(token) {
      if (!canDraw() || token !== generation) return;
      if (typeof video.requestVideoFrameCallback === 'function') {
        rvfc = video.requestVideoFrameCallback(() => {
          rvfc = null;
          if (token !== generation || !canDraw()) return;
          if (draw()) schedule(token);
        });
      } else {
        // Older browsers have no compositor callback: wait two paint turns
        // after `playing` before announcing the first GPU-composed output.
        raf = env.requestAnimationFrame(() => { raf = env.requestAnimationFrame(() => {
          raf = null;
          if (token !== generation || !canDraw()) return;
          if (draw()) schedule(token);
        }); });
      }
    }
    function sync() {
      cancel();
      if (!wantsPlay || !active || !visible || disposed || !usable) { video.pause(); emit('state'); return; }
      const token = generation;
      Promise.resolve(video.play()).then(() => {
        if (disposed || token !== generation || !canDraw()) return;
        schedule(token); emit('state');
      }).catch(() => { if (!disposed && token === generation) emit('error', {code: 'play_rejected'}); });
    }
    function command(message) {
      if (disposed || !message || typeof message.type !== 'string') return;
      switch (message.type) {
        case 'play': wantsPlay = true; sync(); break;
        case 'pause': wantsPlay = false; sync(); break;
        case 'active': active = message.value === true; if (!active) wantsPlay = false; sync(); break;
        case 'visible': visible = message.value === true; sync(); break;
        case 'position': emit('position', {requestId: message.requestId, time: hasFrame && Number.isFinite(video.currentTime) ? video.currentTime : null}); break;
        case 'dispose': dispose(); break;
      }
    }
    function dispose() {
      if (disposed) return;
      cancel(); disposed = true; wantsPlay = false; video.pause();
      for (const [type, listener] of handlers) video.removeEventListener(type, listener);
      video.removeAttribute('src'); video.load();
      if (gl) { if (texture) gl.deleteTexture(texture); if (buffer) gl.deleteBuffer(buffer); if (program) gl.deleteProgram(program); gl.getExtension('WEBGL_lose_context')?.loseContext(); }
    }
    video.muted = true; video.defaultMuted = true; video.loop = true; video.controls = false; video.playsInline = true; video.removeAttribute('controls');
    listen('loadedmetadata', () => {
      if (!usable) return;
      if (video.videoWidth <= 0 || video.videoHeight !== video.videoWidth * 2) emit('error', {code: 'invalid_packed_dimensions'});
      else emit('ready');
    });
    listen('error', () => emit('error', {code: 'decode_failed'}));
    try { initialize(); } catch (error) { emit('error', diagnostic(error, 'webgl_unavailable')); }
    return {command, dispose, draw};
  }

  function mount() {
    const params = new URLSearchParams(global.location.search);
    const video = global.document.querySelector('#video'), canvas = global.document.querySelector('#output');
    const session = params.get('session') || '';
    const emit = value => {
      // Shader logs contain only the GLSL stage/compiler diagnostic, never the
      // source media URI. Keep the structured error in the host protocol too.
      if (value.type === 'error') global.console.error('[PoseHubPackPlayer]', value.code, value.stage || '', value.detail || '');
      global.parent.postMessage(value, global.location.origin);
    };
    let src;
    try { src = trustedVideoUrl(params.get('src') || '', global.location.href); }
    catch (_) { emit({source:'pose-hub-pack',session,type:'error',code:'invalid_source'}); return; }
    const player = createPackPlayer({video,canvas,
      gl: canvas.getContext('webgl',{alpha:true,premultipliedAlpha:true,antialias:false,preserveDrawingBuffer:false}),
      session,emit,requestAnimationFrame:cb=>global.requestAnimationFrame(cb),cancelAnimationFrame:id=>global.cancelAnimationFrame(id)});
    const receive = event => {
      if (event.origin !== global.location.origin || event.source !== global.parent || event.data?.source !== 'pose-hub-pack-host' || event.data?.session !== session) return;
      player.command(event.data.command);
    };
    const visibility = () => player.command({type:'visible',value:!global.document.hidden});
    global.addEventListener('message',receive); global.document.addEventListener('visibilitychange',visibility);
    global.addEventListener('pagehide',()=>{player.dispose();global.removeEventListener('message',receive);global.document.removeEventListener('visibilitychange',visibility);},{once:true});
    canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();player.dispose();emit({source:'pose-hub-pack',session,type:'error',code:'webgl_context_lost'});});
    video.src = src; video.load();
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = {createPackPlayer,trustedVideoUrl,vertexSource,fragmentSource};
  else mount();
})(typeof window === 'undefined' ? globalThis : window);
