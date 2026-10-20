// Ported from HipLab@99fcc83 android/app/src/main/kotlin/com/ugk/hiplab/MainActivity.kt
// (the method-channel handler), made a Flutter plugin so every app gets it
// by depending on ugk_trainer. Channel: ugk_trainer/training_session.
package com.ugk.trainer

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class UgkTrainerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ugk_trainer/training_session").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.success(false)
            return
        }
        when (call.method) {
            "start" -> {
                val session = (call.argument<Number>("session") ?: 0).toLong()
                val maxMs = (call.argument<Number>("maxMs") ?: 0).toLong()
                val notice = TrainingSessionService.Notice(
                    channelName = call.argument<String>("channelName"),
                    channelDescription = call.argument<String>("channelDescription"),
                    title = call.argument<String>("title"),
                    text = call.argument<String>("text"),
                    icon = call.argument<String>("icon"),
                )
                result.success(
                    session != 0L && TrainingSessionService.start(
                        ctx, session, maxMs, notice,
                        call.argument<Boolean>("mediaPlayback") == true,
                        call.argument<Boolean>("paused") == true,
                        (call.argument<Number>("durationMs") ?: 0).toLong(),
                    ),
                )
            }
            "setPlaybackState" -> {
                val session = (call.argument<Number>("session") ?: 0).toLong()
                result.success(TrainingSessionService.setPlaybackState(
                    ctx, session, call.argument<Boolean>("paused") == true,
                ))
            }
            "stop" -> {
                val session = (call.argument<Number>("session") ?: 0).toLong()
                TrainingSessionService.stop(ctx, session)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }
}
