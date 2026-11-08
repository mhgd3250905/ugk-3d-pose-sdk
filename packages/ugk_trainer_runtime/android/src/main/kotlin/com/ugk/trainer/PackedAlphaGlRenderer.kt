// Original GPU compositor using Android EGL14/GLES20/SurfaceTexture contracts.
// Design references only: Tencent VAP's MIT OES renderer and AndroidX Media3's
// Apache-2.0 external-texture pipeline; no third-party source is copied here.
package com.ugk.trainer

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One decoder input and one RGBA output; no pixel readback or frame timer. */
internal class PackedAlphaGlRenderer(
    private val main: Handler,
    private val onInputReady: (Surface) -> Unit,
    private val onFrameComposed: () -> Unit,
    private val onError: () -> Unit,
) {
    companion object {
        internal const val VERTEX_SHADER = """
            attribute vec2 aPosition;
            attribute vec2 aUv;
            varying vec2 vUv;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vUv = aUv;
            }
        """
        internal const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            #ifdef GL_FRAGMENT_PRECISION_HIGH
            precision highp float;
            #else
            precision mediump float;
            #endif
            uniform samplerExternalOES uTexture;
            uniform mat4 uTextureMatrix;
            uniform vec2 uHalfTexel;
            varying vec2 vUv;
            void main() {
                float x = clamp(vUv.x, uHalfTexel.x, 1.0 - uHalfTexel.x);
                // Canonical GL coordinates are bottom-up. Choose the packed
                // upper RGB/lower alpha regions BEFORE the producer ST matrix.
                float rgbY = clamp(0.5 + vUv.y * 0.5, 0.5 + uHalfTexel.y, 1.0 - uHalfTexel.y);
                float alphaY = clamp(vUv.y * 0.5, uHalfTexel.y, 0.5 - uHalfTexel.y);
                vec2 rgbUv = (uTextureMatrix * vec4(x, rgbY, 0.0, 1.0)).xy;
                vec2 alphaUv = (uTextureMatrix * vec4(x, alphaY, 0.0, 1.0)).xy;
                vec3 rgb = texture2D(uTexture, rgbUv).rgb;
                float alpha = clamp(texture2D(uTexture, alphaUv).r, 0.0, 1.0);
                gl_FragColor = vec4(rgb * alpha, alpha);
            }
        """
    }

    private val thread = HandlerThread("ugk-packed-alpha-gl").apply { start() }
    private val gl = Handler(thread.looper)
    @Volatile private var closing = false
    @Volatile private var outputEpoch = 0L
    private var attachedEpoch = -1L
    @Volatile private var failed = false
    @Volatile private var frameAnnounced = false
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var displayInitialized = false
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var parking: EGLSurface = EGL14.EGL_NO_SURFACE
    private var inputTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null
    private var textureId = 0
    private var program = 0
    private var size = 720
    private var hasImage = false
    private val stMatrix = FloatArray(16)
    private val vertices = ByteBuffer.allocateDirect(16 * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(floatArrayOf(-1f, -1f, 0f, 0f, 1f, -1f, 1f, 0f,
                -1f, 1f, 0f, 1f, 1f, 1f, 1f, 1f))
            position(0)
        }

    fun start(output: Surface) {
        val epoch = ++outputEpoch
        submit {
            initialize()
            replaceWindow(output, epoch)
            val names = IntArray(1)
            GLES20.glGenTextures(1, names, 0)
            textureId = names[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            program = linkProgram()
            val texture = SurfaceTexture(textureId)
            inputTexture = texture
            texture.setDefaultBufferSize(size, size * 2)
            texture.setOnFrameAvailableListener({
                if (!closing && !failed) {
                    try {
                        makeCurrent()
                        texture.updateTexImage()
                        texture.getTransformMatrix(stMatrix)
                        hasImage = true
                        draw()
                    } catch (_: Exception) {
                        // Cleanup invalidates queued frame work before EGL tears
                        // the old window down. It is not a decoder failure.
                        if (attachedEpoch == outputEpoch) fail()
                    }
                }
            }, gl)
            val surface = Surface(texture)
            inputSurface = surface
            main.post { if (!closing && !failed) onInputReady(surface) }
        }
    }

    fun attachOutput(output: Surface, width: Int) {
        val epoch = ++outputEpoch
        submit {
            size = width
            inputTexture?.setDefaultBufferSize(width, width * 2)
            replaceWindow(output, epoch)
            // A paused player does not produce another frame after a surface
            // recreation. Its existing OES image can be redrawn without a seek.
            if (hasImage) draw()
        }
    }

    fun detachOutput() {
        ++outputEpoch
        submit { destroyWindow() }
    }

    private fun submit(action: () -> Unit) {
        if (closing) return
        gl.post {
            if (closing || failed) return@post
            try { action() } catch (_: Exception) { fail() }
        }
    }

    private fun initialize() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY)
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1))
        displayInitialized = true
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_DEPTH_SIZE, 0, EGL14.EGL_STENCIL_SIZE, 0, EGL14.EGL_NONE,
        ), 0, configs, 0, 1, count, 0) && count[0] > 0)
        config = requireNotNull(configs[0])
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        check(context != EGL14.EGL_NO_CONTEXT)
        parking = EGL14.eglCreatePbufferSurface(display, config,
            intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        check(parking != EGL14.EGL_NO_SURFACE)
        makeCurrent()
    }

    private fun replaceWindow(output: Surface, epoch: Long) {
        destroyWindow()
        if (epoch != outputEpoch) return
        check(output.isValid)
        window = EGL14.eglCreateWindowSurface(display, config, output,
            intArrayOf(EGL14.EGL_NONE), 0)
        check(window != EGL14.EGL_NO_SURFACE)
        attachedEpoch = epoch
        makeCurrent()
    }

    private fun makeCurrent() {
        val surface = if (window != EGL14.EGL_NO_SURFACE) window else parking
        check(EGL14.eglMakeCurrent(display, surface, surface, context))
    }

    private fun destroyWindow() {
        if (display == EGL14.EGL_NO_DISPLAY || context == EGL14.EGL_NO_CONTEXT) return
        check(EGL14.eglMakeCurrent(display, parking, parking, context))
        if (window != EGL14.EGL_NO_SURFACE) check(EGL14.eglDestroySurface(display, window))
        window = EGL14.EGL_NO_SURFACE
        attachedEpoch = -1L
    }

    private fun draw() {
        val epoch = attachedEpoch
        if (window == EGL14.EGL_NO_SURFACE || epoch != outputEpoch || closing) return
        makeCurrent()
        GLES20.glViewport(0, 0, size, size)
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        val position = GLES20.glGetAttribLocation(program, "aPosition")
        val uv = GLES20.glGetAttribLocation(program, "aUv")
        vertices.position(0)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 16, vertices)
        GLES20.glEnableVertexAttribArray(position)
        vertices.position(2)
        GLES20.glVertexAttribPointer(uv, 2, GLES20.GL_FLOAT, false, 16, vertices)
        GLES20.glEnableVertexAttribArray(uv)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTexture"), 0)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTextureMatrix"), 1, false, stMatrix, 0)
        GLES20.glUniform2f(GLES20.glGetUniformLocation(program, "uHalfTexel"), .5f / size, .25f / size)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(position)
        GLES20.glDisableVertexAttribArray(uv)
        check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
        check(EGL14.eglSwapBuffers(display, window))
        // Publish only a composed buffer, not MediaPlayer's input rendering-start.
        if (!frameAnnounced) main.post {
            if (!closing && !failed && epoch == outputEpoch && !frameAnnounced) {
                frameAnnounced = true
                onFrameComposed()
            }
        }
    }

    private fun linkProgram(): Int {
        fun compile(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            try {
                GLES20.glShaderSource(shader, source)
                GLES20.glCompileShader(shader)
                val success = IntArray(1)
                GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, success, 0)
                check(success[0] != 0)
                return shader
            } catch (error: Exception) {
                GLES20.glDeleteShader(shader)
                throw error
            }
        }
        val vertex = compile(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        var fragment = 0
        val linked = GLES20.glCreateProgram()
        try {
            fragment = compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
            GLES20.glAttachShader(linked, vertex)
            GLES20.glAttachShader(linked, fragment)
            GLES20.glLinkProgram(linked)
            val success = IntArray(1)
            GLES20.glGetProgramiv(linked, GLES20.GL_LINK_STATUS, success, 0)
            check(success[0] != 0)
            return linked
        } catch (error: Exception) {
            GLES20.glDeleteProgram(linked)
            throw error
        } finally {
            GLES20.glDeleteShader(vertex)
            if (fragment != 0) GLES20.glDeleteShader(fragment)
        }
    }

    private fun fail() {
        if (failed || closing) return
        failed = true
        main.post { if (!closing) onError() }
    }

    /** Acknowledge only after queued GL work is retired; the caller then releases
     * the SurfaceProducer and its file pin. Never block the Android main thread.
     */
    fun dispose(onDisposed: (Boolean) -> Unit) {
        if (closing) return
        closing = true
        ++outputEpoch
        gl.post {
            var clean = true
            fun release(action: () -> Unit) {
                try { action() } catch (_: Exception) { clean = false }
            }
            try {
                var current = false
                if (displayInitialized && context != EGL14.EGL_NO_CONTEXT) {
                    try { makeCurrent(); current = true } catch (_: Exception) {}
                }
                release { inputTexture?.setOnFrameAvailableListener(null) }
                release { inputSurface?.release() }
                inputSurface = null
                release { inputTexture?.release() }
                inputTexture = null
                // Destroying a context also retires its objects if it could not
                // be made current after a platform surface/context loss.
                if (current) {
                    release { if (textureId != 0) GLES20.glDeleteTextures(1, intArrayOf(textureId), 0) }
                    release { if (program != 0) GLES20.glDeleteProgram(program) }
                }
                if (displayInitialized) {
                    release { check(EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)) }
                    release { if (window != EGL14.EGL_NO_SURFACE) check(EGL14.eglDestroySurface(display, window)) }
                    release { if (parking != EGL14.EGL_NO_SURFACE) check(EGL14.eglDestroySurface(display, parking)) }
                    release { if (context != EGL14.EGL_NO_CONTEXT) check(EGL14.eglDestroyContext(display, context)) }
                    release { check(EGL14.eglTerminate(display)) }
                }
                release { check(EGL14.eglReleaseThread()) }
            } finally {
                thread.quitSafely()
                main.post { onDisposed(clean) }
            }
        }
    }
}
