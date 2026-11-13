package com.ski.find

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Keeps sharing this phone's location while the app is closed.
 * Android requires a small ongoing notification for this.
 */
class LocationService : Service() {

    companion object {
        private const val TAG = "SkiFind"
        const val CHANNEL = "sharing"
        private const val NOTIF_ID = 7
        private const val INTERVAL_MS = 60_000L        // GPS check every minute
        private const val HEARTBEAT_MS = 10 * 60_000L  // upload at least every 10 minutes even when still
        private const val MOVE_METERS = 25f            // otherwise upload when moved this far

        fun hasForeground(ctx: Context) =
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

        fun hasBackground(ctx: Context) =
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED

        /** Starts (or nudges for a fresh fix) the sharing service if it should run. */
        fun start(ctx: Context) {
            val prefs = Prefs(ctx)
            if (prefs.circleId == null || !prefs.sharing || !hasForeground(ctx)) return
            try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, LocationService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "Couldn't start sharing service", e)
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, LocationService::class.java))
        }

        fun ensureChannel(ctx: Context) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Location sharing", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Shown while Ski Find shares your location"
                        setShowBadge(false)
                    }
                )
            }
        }

        fun batteryInfo(ctx: Context): Pair<Int?, Boolean> {
            val bm = ctx.getSystemService(BatteryManager::class.java)
            val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)?.takeIf { it in 0..100 }
            val status = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                ?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
            return level to charging
        }
    }

    private lateinit var fused: FusedLocationProviderClient
    private lateinit var cloud: Cloud
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val uploadLock = Mutex()
    private var listening = false
    @Volatile private var lastFix: Location? = null

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.lastLocation?.let { onFix(it, force = false) }
        }
    }

    override fun onCreate() {
        super.onCreate()
        fused = LocationServices.getFusedLocationProviderClient(this)
        cloud = Cloud(this)
        ensureChannel(this)
        // Heartbeat so your partner can see you're still sharing while you sit still.
        scope.launch {
            while (isActive) {
                delay(HEARTBEAT_MS)
                lastFix?.let { onFix(it, force = true) }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = cloud.prefs
        try {
            val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
            ServiceCompat.startForeground(this, NOTIF_ID, notification(), type)
        } catch (e: Exception) {
            // Android refuses if location permission was taken away while we were in the background.
            Log.w(TAG, "startForeground refused", e)
            stopSelf()
            return START_NOT_STICKY
        }
        if (prefs.circleId == null || !prefs.sharing || !hasForeground(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!listening) {
            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, INTERVAL_MS)
                .setMinUpdateIntervalMillis(INTERVAL_MS / 2)
                .setWaitForAccurateLocation(false)
                .build()
            fused.requestLocationUpdates(request, callback, Looper.getMainLooper())
            listening = true
        }
        // Every start (app opened, boot, toggle) also sends a fresh position right away.
        fused.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null)
            .addOnSuccessListener { loc -> if (loc != null) onFix(loc, force = true) }
        return START_STICKY
    }

    private fun onFix(loc: Location, force: Boolean) {
        lastFix = loc
        val prefs = cloud.prefs
        val cid = prefs.circleId ?: return
        if (!prefs.sharing) return
        val moved = FloatArray(1)
        Location.distanceBetween(prefs.lastUploadLat, prefs.lastUploadLng, loc.latitude, loc.longitude, moved)
        val stale = System.currentTimeMillis() - prefs.lastUploadAt > HEARTBEAT_MS
        if (!force && !stale && moved[0] < MOVE_METERS) return
        scope.launch {
            uploadLock.withLock {
                try {
                    val (battery, charging) = batteryInfo(this@LocationService)
                    cloud.uploadLocation(
                        cid, loc.latitude, loc.longitude,
                        loc.accuracy.toDouble(), if (loc.hasSpeed()) loc.speed.toDouble() else 0.0,
                        battery, charging, sharing = true,
                    )
                    prefs.lastUploadAt = System.currentTimeMillis()
                    prefs.lastUploadLat = loc.latitude
                    prefs.lastUploadLng = loc.longitude
                } catch (e: HttpError) {
                    Log.w(TAG, "upload failed", e)
                    val removed = e.code == 403 &&
                        runCatching { cloud.loadCircle(cid) == null }.getOrDefault(false)
                    if (removed) {
                        // Removed from the circle on the other phone.
                        prefs.circleId = null
                        stopSelf()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "upload failed (offline?)", e)
                }
            }
        }
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_find)
            .setContentTitle("Sharing your location")
            .setContentText("Ski Find · tap to see the map")
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    override fun onDestroy() {
        if (listening) fused.removeLocationUpdates(callback)
        listening = false
        scope.cancel()
        super.onDestroy()
    }
}
