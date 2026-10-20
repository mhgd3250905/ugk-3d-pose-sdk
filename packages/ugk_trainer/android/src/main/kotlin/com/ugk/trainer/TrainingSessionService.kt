// Ported from HipLab@99fcc83 android/app/src/main/kotlin/com/ugk/hiplab/TrainingSessionService.kt.
// Changes: package com.ugk.trainer (ugk_trainer plugin); notification channel,
// title, text and small icon come from the app over the channel ([Notice]);
// wake-lock tag "ugk_trainer:training"; actions com.ugk.trainer.action.*.
// Guided audio owners additionally publish their real playback state through
// one framework MediaSession. Self-check holds remain generic notifications.
package com.ugk.trainer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

/**
 * Keeps a training session (player / hip check) running while the app is in
 * the background or the screen is locked (Android voice fix, 2026-10-19).
 *
 * Without it a backgrounded HipLab is an ordinary cached process: it is put
 * in the background CPU group (little cores, low CPU share), the device may
 * suspend between two voice lines, and on Android 15+ an app that is neither
 * the top app nor running a foreground service is refused audio focus
 * (AUDIOFOCUS_REQUEST_FAILED) – every coaching line asks for it. Battery
 * whitelisting and auto-start do not change any of that.
 *
 * A `mediaPlayback` foreground service lifts the process to foreground-service
 * priority and holds a partial wake lock so the session clock and the voice
 * keep their timing. It does not play audio itself (just_audio does) and shows
 * one low-importance ongoing notification. Started from Dart over the
 * `ugk_trainer/training_session` channel when a training starts and stopped when it
 * is over (finished, stopped, left); also stopped with the task.
 *
 * PR #24 review (2026-10-19), F24-3 / F24-4: every request carries the id of
 * the training session it belongs to. [desiredSession] is the one session that
 * should be kept alive (0 = none), written on the main thread by [start] /
 * [stop] before the intent goes out. When a request is delivered the service
 * acts on that latest wish, not on the request alone: a STOP that arrives after
 * a newer START was sent (quick leave and re-enter) is ignored, so it can no
 * longer drop the new session's wake lock and foreground state; a START that
 * arrives after its session already ended does not take a lock. A real stop
 * ends with stopSelfResult(startId), which keeps the service if a newer start
 * is still on its way. The wake lock times out after the Dart side's cap
 * (planned length + margin, at most 2 h) instead of a fixed 3 h.
 */
class TrainingSessionService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var mediaSession: MediaSession? = null
    private var playbackPaused = true
    private var playbackPositionMs = 0L
    private var playbackUpdatedAt = 0L
    private val handler = Handler(Looper.getMainLooper())
    private var expiry: Runnable? = null
    private var lastStartId = 0

    /** Session whose wake lock / foreground state this service holds now. */
    private var heldSession = 0L

    /** Notification texts of the latest start (app-provided). */
    data class Notice(
        val channelName: String?,
        val channelDescription: String?,
        val title: String?,
        val text: String?,
        val icon: String?,
    )

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        val session = intent?.getLongExtra(EXTRA_SESSION, 0L) ?: 0L
        val wanted = desiredSession
        val update = intent?.action == ACTION_STATE
        val decision = decide(intent?.action == ACTION_STOP, session, wanted)
        // Only a current START takes ownership; a state update may arrive
        // while its START is still pending and must not create a phantom hold.
        // Always enter the foreground first: a service started with
        // startForegroundService must call startForeground even when the
        // request that reached it is a stop.
        try {
            if (decision == Decision.HOLD && (!update || heldSession == session)) {
                if (!update && heldSession != session) {
                    releaseMediaSession()
                    heldSession = session
                }
                syncMediaSession()
            }
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed", e)
            if (desiredSession == intent?.getLongExtra(EXTRA_SESSION, 0L)) {
                desiredSession = 0L
            }
            finish(startId)
            return START_NOT_STICKY
        }
        when (decision) {
            Decision.HOLD -> {
                // A pause/resume update only changes PlaybackState and the
                // notification. It cannot extend a forgotten session's cap.
                if (update) return START_NOT_STICKY
                val cap = intent?.getLongExtra(EXTRA_MAX_MS, DEFAULT_CAP_MS) ?: DEFAULT_CAP_MS
                heldSession = session
                val boundedCap = cap.coerceIn(MIN_CAP_MS, MAX_CAP_MS)
                try {
                    acquireWakeLock(boundedCap)
                    armExpiry(session, boundedCap)
                } catch (e: Exception) {
                    Log.w(TAG, "could not hold training session", e)
                    if (desiredSession == session) desiredSession = 0L
                    finish(startId)
                    return START_NOT_STICKY
                }
                Log.i(TAG, "training session $session held (cap ${cap / 1000} s)")
            }
            Decision.FINISH -> {
                Log.i(TAG, "training session $session over")
                finish(startId)
            }
            Decision.IGNORE -> {
                // A newer session's START is (or will be) delivered; keep its
                // wake lock and foreground state untouched.
                Log.i(TAG, "stale request for session $session ignored (wanted $wanted, holding $heldSession)")
            }
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        desiredSession = 0L
        releaseResources()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (desiredSession == heldSession) desiredSession = 0L
        releaseResources()
        Log.i(TAG, "training session service stopped")
        super.onDestroy()
    }

    /** Ends this service unless a newer start request is still pending. */
    private fun finish(startId: Int) {
        releaseResources()
        stopForeground(STOP_FOREGROUND_REMOVE) // minSdk 24
        if (!stopSelfResult(startId)) {
            Log.i(TAG, "a newer start is pending; service kept")
        }
    }

    private fun acquireWakeLock(capMs: Long) {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = wakeLock ?: pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ugk_trainer:training").apply {
            setReferenceCounted(false)
        }
        wakeLock = lock
        // Not reference counted: acquiring again (new session, or a renew
        // after a long pause) re-arms the timeout. Safety cap only – the
        // lock is released as soon as the training is over.
        lock.acquire(capMs)
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    /** A timed-out hold must drop its media token/notification too. A wake
     * lock timeout alone otherwise leaves a false active playback session. */
    private fun armExpiry(session: Long, capMs: Long) {
        expiry?.let(handler::removeCallbacks)
        val deadline = Runnable {
            // The old owner's timer must never stop a pending newer START.
            if (heldSession != session || (desiredSession != session && desiredSession != 0L)) {
                return@Runnable
            }
            if (desiredSession == session) desiredSession = 0L
            Log.i(TAG, "training session $session safety cap reached")
            finish(lastStartId)
        }
        expiry = deadline
        handler.postDelayed(deadline, capMs)
    }

    private fun releaseResources() {
        expiry?.let(handler::removeCallbacks)
        expiry = null
        try {
            releaseMediaSession()
        } finally {
            releaseWakeLock()
            heldSession = 0L
        }
    }

    private fun syncMediaSession() {
        if (!wantsMediaPlayback) {
            releaseMediaSession()
            return
        }
        val media = mediaSession ?: MediaSession(this, "ugk_trainer:guided").also {
            // No advertised external controls: playback stays with the App.
            it.setFlags(0)
            it.setMediaButtonReceiver(null)
            mediaSession = it
            playbackPaused = true
            playbackPositionMs = 0L
            playbackUpdatedAt = SystemClock.elapsedRealtime()
        }
        val now = SystemClock.elapsedRealtime()
        if (!playbackPaused) playbackPositionMs += now - playbackUpdatedAt
        playbackUpdatedAt = now
        playbackPaused = wantsPaused
        media.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, notice.title ?: notice.channelName ?: "Training")
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, notice.text ?: "")
            .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs.coerceAtLeast(0L))
            .build())
        media.setPlaybackState(PlaybackState.Builder()
            .setActions(0L)
            .setState(
                if (playbackPaused) PlaybackState.STATE_PAUSED else PlaybackState.STATE_PLAYING,
                playbackPositionMs,
                if (playbackPaused) 0f else 1f,
                now,
            )
            .build())
        media.isActive = true
    }

    private fun releaseMediaSession() {
        val media = mediaSession
        mediaSession = null
        if (media != null) {
            try {
                media.setPlaybackState(PlaybackState.Builder()
                    .setActions(0L)
                    .setState(PlaybackState.STATE_STOPPED, playbackPositionMs, 0f)
                    .build())
                media.isActive = false
            } finally {
                media.release()
            }
        }
        playbackPaused = true
        playbackPositionMs = 0L
        playbackUpdatedAt = 0L
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    notice.channelName ?: "Training",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = notice.channelDescription ?: ""
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = open?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(smallIcon())
            .setContentTitle(notice.title ?: "")
            .setContentText(notice.text ?: "")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(if (mediaSession != null) Notification.CATEGORY_TRANSPORT else Notification.CATEGORY_SERVICE)
            .apply {
                if (pending != null) {
                    setContentIntent(pending)
                    mediaSession?.setSessionActivity(pending)
                }
                mediaSession?.let { setStyle(Notification.MediaStyle().setMediaSession(it.sessionToken)) }
            }
            .build()
    }

    /** `mipmap/name` or `drawable/name` from the app, else the app icon. */
    private fun smallIcon(): Int {
        val name = notice.icon
        if (name != null) {
            val parts = name.split('/')
            val id = if (parts.size == 2) {
                resources.getIdentifier(parts[1], parts[0], packageName)
            } else {
                resources.getIdentifier(name, "drawable", packageName)
            }
            if (id != 0) return id
        }
        return applicationInfo.icon
    }

    internal enum class Decision { HOLD, FINISH, IGNORE }

    companion object {
        private const val TAG = "UgkTrainingService"
        private const val CHANNEL_ID = "training_session"
        private const val NOTIFICATION_ID = 4107
        private const val ACTION_START = "com.ugk.trainer.action.START_TRAINING_SESSION"
        private const val ACTION_STOP = "com.ugk.trainer.action.STOP_TRAINING_SESSION"
        private const val ACTION_STATE = "com.ugk.trainer.action.TRAINING_PLAYBACK_STATE"
        private const val EXTRA_SESSION = "session"
        private const val EXTRA_MAX_MS = "maxMs"
        private const val MIN_CAP_MS = 5L * 60 * 1000
        private const val MAX_CAP_MS = 2L * 60 * 60 * 1000
        private const val DEFAULT_CAP_MS = 30L * 60 * 1000

        /** Texts of the notification (set by the latest [start]). */
        @Volatile
        private var notice = Notice(null, null, null, null, null)

        /** The session that should be kept alive now; 0 = none. */
        @Volatile
        private var desiredSession = 0L
        private var wantsMediaPlayback = false
        private var wantsPaused = false
        private var durationMs = 0L

        /**
         * What a delivered request does, given the latest wish. Pure, so the
         * rule is easy to check:
         *  - START for the wanted session → hold (also re-arms the cap);
         *  - STOP when nothing is wanted → finish (stopSelfResult keeps the
         *    service if a newer START is still pending);
         *  - START whose session already ended, nothing newer → finish;
         *  - anything for another session while a newer one is wanted →
         *    ignore (that session's own START does the work).
         */
        internal fun decide(isStop: Boolean, session: Long, wanted: Long): Decision = when {
            !isStop && session != 0L && session == wanted -> Decision.HOLD
            wanted == 0L -> Decision.FINISH
            else -> Decision.IGNORE
        }

        /** True when the request reached the system. */
        fun start(
            context: Context,
            session: Long,
            maxMs: Long,
            notice: Notice,
            mediaPlayback: Boolean,
            paused: Boolean,
            durationMs: Long,
        ): Boolean {
            desiredSession = session
            this.notice = notice
            wantsMediaPlayback = mediaPlayback
            wantsPaused = paused
            this.durationMs = durationMs
            val intent = Intent(context, TrainingSessionService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_SESSION, session)
                .putExtra(EXTRA_MAX_MS, maxMs)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (e: Exception) {
                // e.g. ForegroundServiceStartNotAllowedException when asked
                // from the background; the session still runs in the
                // foreground as before.
                if (desiredSession == session) {
                    desiredSession = 0L
                    // No successful newer owner exists. A pre-existing service
                    // must not retain the failed replacement's old media token.
                    context.stopService(Intent(context, TrainingSessionService::class.java))
                }
                Log.w(TAG, "could not start training session service", e)
                false
            }
        }

        /** State updates are scoped to the current media owner. They never
         * start a new session, acquire a lock, or reset its safety timeout. */
        fun setPlaybackState(context: Context, session: Long, paused: Boolean): Boolean {
            if (session == 0L || session != desiredSession || !wantsMediaPlayback) return false
            wantsPaused = paused
            return try {
                context.startService(Intent(context, TrainingSessionService::class.java)
                    .setAction(ACTION_STATE)
                    .putExtra(EXTRA_SESSION, session))
                true
            } catch (e: Exception) {
                Log.w(TAG, "could not update training playback state", e)
                false
            }
        }

        /** Ends [session]; a stop for a session that is no longer current is dropped. */
        fun stop(context: Context, session: Long) {
            if (session != desiredSession) return
            desiredSession = 0L
            val intent = Intent(context, TrainingSessionService::class.java)
                .setAction(ACTION_STOP)
                .putExtra(EXTRA_SESSION, session)
            try {
                // Routed through onStartCommand so a service that has not
                // reached startForeground yet still does so before stopping.
                context.startService(intent)
            } catch (e: Exception) {
                // Background start of a stopped service is refused: then it
                // is not running. Only stop it outright if nothing newer was
                // asked for in the meantime (same thread, so nothing was).
                if (desiredSession == 0L) {
                    context.stopService(Intent(context, TrainingSessionService::class.java))
                }
            }
        }
    }
}
