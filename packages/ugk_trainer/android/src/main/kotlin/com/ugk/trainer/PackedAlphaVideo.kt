// Original SDK adapter built from Android MediaPlayer and Flutter's documented
// SurfaceProducer contracts. Source/design notes: packed_alpha_sources.md.
package com.ugk.trainer

import android.media.MediaPlayer
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
                val asset = call.argument<String>("asset") ?: error("Missing asset")
                val id = nextId++
                val producer = binding.textureRegistry.createSurfaceProducer()
                val player = try { Player(id, producer) } catch (error: Exception) {
                    producer.release()
                    throw error
                }
                players[id] = player
                try {
                    player.prepare(asset)
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

        private fun emit(type: String, fields: Map<String, Any?> = emptyMap()) {
            if (!disposed) publish(id, type, fields)
        }

        fun prepare(asset: String) {
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
                if (!disposed) emit("error", mapOf("what" to what, "extra" to extra))
                true
            }
            val key = binding.flutterAssets.getAssetFilePathByName(asset)
            binding.applicationContext.assets.openFd(key).use {
                media.setDataSource(it.fileDescriptor, it.startOffset, it.length)
            }
            media.prepareAsync()
        }

        fun play() { wantsPlay = true; syncPlayback() }
        fun pause() { wantsPlay = false; syncPlayback() }
        fun setActive(value: Boolean) { active = value; if (!value) wantsPlay = false; syncPlayback() }
        fun setVisible(value: Boolean) { visible = value; syncPlayback() }
        fun position(): Double? = if (prepared && !disposed) media.currentPosition / 1000.0 else null

        private fun syncPlayback() {
            if (!prepared || disposed) return
            val play = wantsPlay && active && visible && surfaceAvailable
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
            syncPlayback()
            media.setSurface(null)
        }

        fun dispose() {
            if (disposed) return
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
