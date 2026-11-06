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
                val player = try { Player(id, producer) } catch (error: Exception) {
                    producer.release()
                    throw error
                }
                players[id] = player
                try {
                    player.prepare(asset, external)
                    result.success(mapOf("playerId" to id, "textureId" to producer.id()))
                } catch (error: Exception) {
                    players.remove(id)
                    player.dispose()
                    throw error
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
                "return-to-start" -> {
                    player.returnToStart(
                        (call.argument<Number>("value") ?: 400).toLong(), result)
                    return
                }
                "cancel-return-to-start" -> player.cancelReturnToStart()
                "dispose" -> { players.remove(id); player.dispose() }
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
    ) : TextureRegistry.SurfaceProducer.Callback {
        private val media = MediaPlayer()
        private var prepared = false
        private var disposed = false
        private var wantsPlay = false
        private var active = true
        private var visible = true
        private var surfaceAvailable = true
        private var firstFrame = false
        private var returnRequest: ReturnRequest? = null

        private fun emit(type: String, fields: Map<String, Any?> = emptyMap()) {
            if (!disposed) publish(id, type, fields)
        }

        fun prepare(asset: String?, sourceUri: Uri?) {
            producer.setSize(720, 1440)
            producer.setCallback(this)
            media.setSurface(producer.surface)
            media.setOnPreparedListener {
                if (disposed) return@setOnPreparedListener
                val width = media.videoWidth
                val height = media.videoHeight
                if (width <= 0 || height != width * 2) {
                    emit("error", mapOf("code" to "invalid_packed_dimensions"))
                    return@setOnPreparedListener
                }
                producer.setSize(width, height)
                prepared = true
                media.isLooping = true
                media.setVolume(0f, 0f)
                emit("ready", mapOf("width" to width, "height" to height,
                    "duration" to media.duration / 1000.0))
                syncPlayback()
            }
            media.setOnInfoListener { _, what, _ ->
                if (!disposed && what == MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START && !firstFrame) {
                    firstFrame = true
                    emit("first-frame")
                }
                true
            }
            media.setOnErrorListener { _, what, extra ->
                finishReturn(false, resume = false)
                if (!disposed) emit("error", mapOf("what" to what, "extra" to extra))
                true
            }
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
            syncPlayback()
        }
        fun pause() {
            wantsPlay = false
            cancelReturnToStart()
            syncPlayback()
        }
        fun setActive(value: Boolean) {
            active = value
            if (!value) { wantsPlay = false; cancelReturnToStart() }
            syncPlayback()
        }
        fun setVisible(value: Boolean) {
            visible = value
            if (!value) cancelReturnToStart()
            syncPlayback()
        }
        fun position(): Double? = if (prepared && !disposed) media.currentPosition / 1000.0 else null

        /** Optional, bounded preparation while the demonstration route is current.
         * Run forward through the remaining poses; never jump straight from an
         * arbitrary middle pose to zero. A paused preview may play temporarily.
         */
        fun returnToStart(durationMs: Long, result: MethodChannel.Result) {
            if (returnRequest != null || !prepared || !firstFrame || disposed ||
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
            val play = (wantsPlay || returnRequest != null) && active && visible && surfaceAvailable
            if (play && !media.isPlaying) media.start()
            else if (!play && media.isPlaying) media.pause()
            emit("state", mapOf("playing" to media.isPlaying))
        }

        override fun onSurfaceAvailable() {
            if (disposed) return
            surfaceAvailable = true
            media.setSurface(producer.surface)
            syncPlayback()
        }

        override fun onSurfaceCleanup() {
            if (disposed) return
            surfaceAvailable = false
            cancelReturnToStart()
            syncPlayback()
            media.setSurface(null)
        }

        fun dispose() {
            if (disposed) return
            finishReturn(false, resume = false)
            disposed = true
            prepared = false
            pendingEvents.remove(id)
            media.setOnInfoListener(null)
            media.setOnErrorListener(null)
            media.setOnPreparedListener(null)
            media.release()
            producer.release()
        }
    }
}
