// Original SDK adapter built from Android MediaPlayer and Flutter's documented
// SurfaceProducer contracts. Source/design notes: packed_alpha_sources.md.
package com.ugk.trainer

import android.media.MediaPlayer
import android.media.PlaybackParams
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/** Muted Android texture player. Only explicit commands query currentPosition. */
internal class PackedAlphaVideoHost(
    private val binding: FlutterPlugin.FlutterPluginBinding,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methods = MethodChannel(binding.binaryMessenger, "ugk_trainer/packed_alpha")
    private val events = EventChannel(binding.binaryMessenger, "ugk_trainer/packed_alpha/events")
    private var sink: EventChannel.EventSink? = null
    private val players = mutableMapOf<Long, Player>()
    private val handler = Handler(Looper.getMainLooper())

    private class ReturnRequest(val result: MethodChannel.Result) {
        var timeout: Runnable? = null
        var seeking = false
    }
    private class PrimeRequest(val result: MethodChannel.Result) {
        var timeout: Runnable? = null
    }
    // Creation and EventChannel.listen use different channels. Retain at most
    // one ready/state/first-frame/error event per player until listen arrives.
    private val pendingEvents = mutableMapOf<Long, LinkedHashMap<String, Map<String, Any?>>>()
    private var nextId = 1L

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
        pendingEvents.forEach { (id, pending) ->
            if (players.containsKey(id)) pending.values.forEach { eventSink.success(it) }
        }
        pendingEvents.clear()
    }
    override fun onCancel(arguments: Any?) { sink = null }

    private fun publish(id: Long, type: String, fields: Map<String, Any?>) {
        if (!players.containsKey(id)) return
        val event = mapOf("playerId" to id, "type" to type) + fields
        val target = sink
        if (target != null) target.success(event)
        else pendingEvents.getOrPut(id) { linkedMapOf() }[type] = event
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (call.method == "create") {
                val asset = call.argument<String>("asset")
                val sourceUri = call.argument<String>("sourceUri")
                require((asset != null) != (sourceUri != null)) { "One packed source is required" }
                val external = sourceUri?.let { validateSourceUri(it) }
                val id = nextId++
                val producer = binding.textureRegistry.createSurfaceProducer()
                val player = try {
                    Player(id, producer, call.argument<Boolean>("nativeAlpha") == true)
                } catch (error: Exception) {
                    producer.release()
                    throw error
                }
                players[id] = player
                try {
                    player.prepare(asset, external)
                    result.success(mapOf("playerId" to id, "textureId" to producer.id()))
                } catch (error: Exception) {
                    players.remove(id)
                    player.dispose { _ -> result.error("packed_alpha", error.javaClass.simpleName, null) }
                }
                return
            }
            val id = call.argument<Number>("playerId")?.toLong()
            val player = players[id]
            if (player == null) { result.success(null); return }
            when (call.method) {
                "play" -> player.play()
                "pause" -> player.pause()
                "active" -> player.setActive(call.argument<Boolean>("value") == true)
                "visible" -> player.setVisible(call.argument<Boolean>("value") == true)
                "position" -> { result.success(player.position()); return }
                "prime-first-frame" -> { player.prepareFirstFrame(result); return }
                "cancel-prime-first-frame" -> player.cancelPrepareFirstFrame()
                "return-to-start" -> {
                    player.returnToStart(
                        (call.argument<Number>("value") ?: 400).toLong(), result)
                    return
                }
                "cancel-return-to-start" -> player.cancelReturnToStart()
                "dispose" -> {
                    players.remove(id)
                    player.dispose { success ->
                        if (success) result.success(null)
                        else result.error("packed_alpha", "dispose_failed", null)
                    }
                    return
                }
                else -> { result.notImplemented(); return }
            }
            result.success(null)
        } catch (error: Exception) {
            // The Dart surface converts this into the existing media failure
            // protocol and the host selects the ordinary MP4 fallback.
            result.error("packed_alpha", error.javaClass.simpleName, null)
        }
    }

    private fun validateSourceUri(value: String): Uri {
        val uri = Uri.parse(value)
        require(uri.isAbsolute && uri.scheme in setOf("file", "http", "https"))
        require(uri.userInfo == null && uri.query == null && uri.fragment == null)
        val path = uri.path ?: error("Missing media path")
        require(path.startsWith("/") && path.endsWith(".mp4", ignoreCase = true))
        require(uri.pathSegments.none { it == "." || it == ".." })
        if (uri.scheme == "file") {
            require(uri.host.isNullOrEmpty())
            val file = File(path)
            require(file.isAbsolute && file.isFile)
        } else require(!uri.host.isNullOrEmpty())
        return uri
    }

    fun dispose() {
        players.values.toList().forEach { it.dispose() }
        players.clear()
        pendingEvents.clear()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    private inner class Player(
        private val id: Long,
        private val producer: TextureRegistry.SurfaceProducer,
        private val nativeAlpha: Boolean,
    ) : TextureRegistry.SurfaceProducer.Callback {
        private val media = MediaPlayer()
        private var prepared = false
        private var disposed = false
        private var wantsPlay = false
        private var active = true
        private var visible = true
        private var surfaceAvailable = true
        private var firstFrame = false
        private var glRenderer: PackedAlphaGlRenderer? = null
        private var outputWidth = 720
        private val disposeCallbacks = mutableListOf<(Boolean) -> Unit>()
        private var releaseResult: Boolean? = null
        private var returnRequest: ReturnRequest? = null
        private var primeRequest: PrimeRequest? = null

        private fun emit(type: String, fields: Map<String, Any?> = emptyMap()) {
            if (!disposed) publish(id, type, fields)
        }

        fun prepare(asset: String?, sourceUri: Uri?) {
            producer.setSize(720, if (nativeAlpha) 720 else 1440)
            producer.setCallback(this)
            media.setOnPreparedListener {
                if (disposed) return@setOnPreparedListener
                val width = media.videoWidth
                val height = media.videoHeight
                if (width <= 0 || height != width * 2) {
                    emit("error", mapOf("code" to "invalid_packed_dimensions"))
                    return@setOnPreparedListener
                }
                outputWidth = width
                producer.setSize(width, if (nativeAlpha) width else height)
                if (nativeAlpha && surfaceAvailable) glRenderer?.attachOutput(producer.surface, width)
                prepared = true
                media.isLooping = true
                media.setVolume(0f, 0f)
                emit("ready", mapOf("width" to width, "height" to height,
                    "duration" to media.duration / 1000.0))
                syncPlayback()
            }
            media.setOnInfoListener { _, what, _ ->
                if (!nativeAlpha && !disposed && what == MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START) {
                    announceFrame()
                }
                true
            }
            media.setOnErrorListener { _, what, extra ->
                finishPrime(false, resume = false)
                finishReturn(false, resume = false)
                if (!disposed) emit("error", mapOf("what" to what, "extra" to extra))
                true
            }
            if (nativeAlpha) {
                glRenderer = PackedAlphaGlRenderer(
                    handler,
                    onInputReady = { input ->
                        if (!disposed) {
                            try {
                                media.setSurface(input)
                                openSource(asset, sourceUri)
                            } catch (_: Exception) {
                                emit("error", mapOf("code" to "native_alpha_prepare"))
                            }
                        }
                    },
                    onFrameComposed = { if (!disposed && surfaceAvailable) announceFrame() },
                    onError = {
                        if (!disposed) {
                            finishPrime(false, resume = false)
                            finishReturn(false, resume = false)
                            emit("error", mapOf("code" to "native_alpha_composition"))
                        }
                    },
                ).also { it.start(producer.surface) }
            } else {
                media.setSurface(producer.surface)
                openSource(asset, sourceUri)
            }
        }

        private fun announceFrame() {
            if (firstFrame) return
            firstFrame = true
            emit("first-frame")
            finishPrime(true)
        }

        private fun openSource(asset: String?, sourceUri: Uri?) {
            if (sourceUri != null) media.setDataSource(binding.applicationContext, sourceUri)
            else {
                val key = binding.flutterAssets.getAssetFilePathByName(requireNotNull(asset))
                binding.applicationContext.assets.openFd(key).use {
                    media.setDataSource(it.fileDescriptor, it.startOffset, it.length)
                }
            }
            media.prepareAsync()
        }

        fun play() {
            wantsPlay = true
            cancelReturnToStart()
            cancelPrepareFirstFrame()
            syncPlayback()
        }
        fun pause() {
            wantsPlay = false
            cancelReturnToStart()
            cancelPrepareFirstFrame()
            syncPlayback()
        }
        fun setActive(value: Boolean) {
            active = value
            if (!value) {
                wantsPlay = false
                cancelReturnToStart()
                cancelPrepareFirstFrame()
            }
            syncPlayback()
        }
        fun setVisible(value: Boolean) {
            visible = value
            if (!value) {
                cancelReturnToStart()
                cancelPrepareFirstFrame()
            }
            syncPlayback()
        }
        fun position(): Double? = if (prepared && !disposed) media.currentPosition / 1000.0 else null

        /** Start only long enough for the first decoded texture frame, then hold
         * it in the same player. This is opt-in; ordinary paused video is idle.
         */
        fun prepareFirstFrame(result: MethodChannel.Result) {
            if (primeRequest != null || returnRequest != null || !prepared ||
                disposed || !active || !visible || !surfaceAvailable) {
                result.success(false)
                return
            }
            if (firstFrame) {
                wantsPlay = false
                syncPlayback()
                result.success(true)
                return
            }
            val request = PrimeRequest(result)
            primeRequest = request
            request.timeout = Runnable {
                if (primeRequest === request) finishPrime(false)
            }
            handler.postDelayed(requireNotNull(request.timeout), 900L)
            try {
                syncPlayback()
            } catch (_: Exception) {
                finishPrime(false)
            }
        }

        fun cancelPrepareFirstFrame() = finishPrime(false)

        private fun finishPrime(success: Boolean, resume: Boolean = true) {
            val request = primeRequest ?: return
            primeRequest = null
            request.timeout?.let { handler.removeCallbacks(it) }
            request.timeout = null
            var completed = success
            try {
                if (completed) wantsPlay = false
                if (prepared && !disposed) {
                    if (resume) syncPlayback()
                    else if (media.isPlaying) media.pause()
                }
            } catch (_: Exception) {
                completed = false
                try { if (media.isPlaying) media.pause() } catch (_: Exception) {}
            }
            request.result.success(completed)
        }

        /** Optional, bounded preparation while the demonstration route is current.
         * Run forward through the remaining poses; never jump straight from an
         * arbitrary middle pose to zero. A paused preview may play temporarily.
         */
        fun returnToStart(durationMs: Long, result: MethodChannel.Result) {
            if (returnRequest != null || primeRequest != null || !prepared || !firstFrame || disposed ||
                !active || !visible || !surfaceAvailable ||
                Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                result.success(false)
                return
            }
            try {
                val duration = media.duration.toLong()
                val position = media.currentPosition.toLong().coerceAtLeast(0L)
                if (duration <= 0L) { result.success(false); return }
                val remaining = (duration - position).coerceAtLeast(0L)
                // Long future clips cannot be squeezed indefinitely. Leave
                // healthy playback alone instead of starting an unfinishable run.
                if (remaining > 12L * 950L) { result.success(false); return }
                val request = ReturnRequest(result)
                returnRequest = request
                request.timeout = Runnable {
                    if (returnRequest === request) finishReturn(false)
                }
                handler.postDelayed(requireNotNull(request.timeout), 1100L)
                media.setOnCompletionListener {
                    if (returnRequest === request) seekStart(request)
                }
                media.setOnSeekCompleteListener {
                    if (returnRequest === request && request.seeking) {
                        // MediaPlayer displays the requested video frame while
                        // paused; the Dart side waits for Flutter composition.
                        finishReturn(media.currentPosition <= 80)
                    }
                }
                if (position <= 35L) {
                    seekStart(request)
                    return
                }
                val target = durationMs.coerceIn(80L, 800L)
                val speed = (remaining.toFloat() / target).coerceIn(1f, 12f)
                media.isLooping = false
                media.playbackParams = PlaybackParams().allowDefaults()
                    .setSpeed(speed).setPitch(1f)
                    .setAudioFallbackMode(PlaybackParams.AUDIO_FALLBACK_MODE_MUTE)
                syncPlayback()
            } catch (_: Exception) {
                // Unsupported speed/seek is a failed optional handoff, not a
                // decoder error that should replace a healthy demonstration.
                if (returnRequest != null) finishReturn(false)
                else result.success(false)
            }
        }

        private fun seekStart(request: ReturnRequest) {
            if (returnRequest !== request || request.seeking) return
            request.seeking = true
            try {
                if (media.isPlaying) media.pause()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    media.seekTo(0L, MediaPlayer.SEEK_CLOSEST)
                } else {
                    @Suppress("DEPRECATION")
                    media.seekTo(0)
                }
            } catch (_: Exception) {
                finishReturn(false)
            }
        }

        fun cancelReturnToStart() = finishReturn(false)

        private fun finishReturn(success: Boolean, resume: Boolean = true) {
            val request = returnRequest ?: return
            returnRequest = null
            request.timeout?.let { handler.removeCallbacks(it) }
            request.timeout = null
            var completed = success
            try {
                media.setOnCompletionListener(null)
                media.setOnSeekCompleteListener(null)
                if (prepared && !disposed) {
                    media.isLooping = true
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        // Setting a nonzero playback speed can start MediaPlayer,
                        // so sync/pause again before acknowledging this request.
                        media.playbackParams = PlaybackParams().allowDefaults()
                            .setSpeed(1f).setPitch(1f)
                    }
                    if (completed) wantsPlay = false
                    if (resume) syncPlayback()
                    else if (media.isPlaying) media.pause()
                }
            } catch (_: Exception) {
                completed = false
                // Still try to stop an accelerated player before reporting false.
                try { if (media.isPlaying) media.pause() } catch (_: Exception) {}
            }
            request.result.success(completed)
        }

        private fun syncPlayback() {
            if (!prepared || disposed) return
            val play = (wantsPlay || returnRequest != null || primeRequest != null) &&
                active && visible && surfaceAvailable
            if (play && !media.isPlaying) media.start()
            else if (!play && media.isPlaying) media.pause()
            emit("state", mapOf("playing" to media.isPlaying))
        }

        override fun onSurfaceAvailable() {
            if (disposed) return
            surfaceAvailable = true
            if (nativeAlpha) glRenderer?.attachOutput(producer.surface, outputWidth)
            else media.setSurface(producer.surface)
            syncPlayback()
        }

        override fun onSurfaceCleanup() {
            if (disposed) return
            surfaceAvailable = false
            cancelReturnToStart()
            cancelPrepareFirstFrame()
            syncPlayback()
            if (nativeAlpha) glRenderer?.detachOutput()
            else media.setSurface(null)
        }

        fun dispose(onDisposed: (Boolean) -> Unit = {}) {
            releaseResult?.let { onDisposed(it); return }
            disposeCallbacks.add(onDisposed)
            if (disposed) return
            finishPrime(false, resume = false)
            finishReturn(false, resume = false)
            disposed = true
            prepared = false
            pendingEvents.remove(id)
            var mediaReleased = true
            fun release(action: () -> Unit) {
                try { action() } catch (_: Exception) { mediaReleased = false }
            }
            release { media.setOnInfoListener(null) }
            release { media.setOnErrorListener(null) }
            release { media.setOnPreparedListener(null) }
            release { media.release() }
            release { producer.setCallback(null) }
            fun finishRelease(glReleased: Boolean) {
                release { producer.release() }
                val success = mediaReleased && glReleased
                releaseResult = success
                val callbacks = disposeCallbacks.toList()
                disposeCallbacks.clear()
                callbacks.forEach { it(success) }
            }
            val renderer = glRenderer
            glRenderer = null
            if (renderer == null) {
                finishRelease(true)
            } else renderer.dispose(::finishRelease)
        }
    }
}
