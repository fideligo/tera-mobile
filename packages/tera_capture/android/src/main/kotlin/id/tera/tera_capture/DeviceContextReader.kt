package id.tera.tera_capture

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock

/**
 * Thermal, battery and clock readings (BUILD_SPEC 6.5 and 6.6).
 *
 * Everything here reports what the platform said or reports that it said nothing. Where an API
 * is unavailable below a version floor, the result is `unsupported` or null — never a
 * substituted value (invariant 9).
 */
/**
 * The two clocks, read the same way everywhere.
 *
 * Every stream stamps each sample with both at the moment of delivery, so the *basis* of the
 * sample's own timestamp can be established empirically rather than assumed from what the
 * platform declares. A device that declares REALTIME but timestamps in uptime would otherwise
 * silently invalidate every offset figure collected from it.
 */
internal object Clocks {
    fun realtimeNanos(): Long = SystemClock.elapsedRealtimeNanos()

    /** Nanosecond-resolved where the platform offers it; millisecond-scaled below API 31. */
    fun uptimeNanos(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SystemClock.uptimeNanos()
        } else {
            SystemClock.uptimeMillis() * 1_000_000L
        }
}

internal class DeviceContextReader(private val context: Context) {

    /**
     * Thermal status and battery state.
     *
     * `getCurrentThermalStatus` needs API 29. Below that the device genuinely cannot tell us,
     * and "unsupported" is the honest answer — reporting `none` would claim the device is cool
     * when the truth is that we do not know.
     */
    fun read(): Map<String, Any?> {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager

        val thermal = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            when (powerManager.currentThermalStatus) {
                PowerManager.THERMAL_STATUS_NONE -> "none"
                PowerManager.THERMAL_STATUS_LIGHT -> "light"
                PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                else -> "unsupported"
            }
        } else {
            "unsupported"
        }

        val batteryStatus: Intent? = context.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        )

        val level = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val batteryPercent = if (level >= 0 && scale > 0) level * 100 / scale else null

        val plugged = batteryStatus?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
        val isCharging = if (plugged < 0) null else plugged != 0

        return mapOf(
            "thermal_status" to thermal,
            "battery_percent" to batteryPercent,
            "is_charging" to isCharging,
            "captured_at_millis" to System.currentTimeMillis(),
        )
    }

    /**
     * Read the two clocks back to back (BUILD_SPEC 6.6).
     *
     * `elapsedRealtimeNanos` counts through deep sleep and is the base a REALTIME camera
     * timestamp uses. `uptimeNanos` stops during deep sleep. Their difference is time spent
     * asleep.
     *
     * The absolute difference does not matter — a constant offset is absorbed by personal
     * calibration. Its *spread across runs* is what a transit-time measurement cannot tolerate,
     * which is why the caller repeats this three times.
     *
     * The two reads are adjacent and in this order deliberately: any work between them shows up
     * as offset that is not really there.
     */
    fun readClockOffset(): Map<String, Any?> {
        val realtimeNanos: Long
        val uptimeNanos: Long
        val nanosecondPrecision: Boolean

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            realtimeNanos = SystemClock.elapsedRealtimeNanos()
            uptimeNanos = SystemClock.uptimeNanos()
            nanosecondPrecision = true
        } else {
            // Below API 31 only uptimeMillis exists, so the offset can be resolved no finer than
            // a millisecond. Reported rather than papered over, because a millisecond is the
            // same order as the effect being measured.
            realtimeNanos = SystemClock.elapsedRealtimeNanos()
            uptimeNanos = SystemClock.uptimeMillis() * 1_000_000L
            nanosecondPrecision = false
        }

        return mapOf(
            "realtime_nanos" to realtimeNanos,
            "uptime_nanos" to uptimeNanos,
            "uptime_nanosecond_precision" to nanosecondPrecision,
        )
    }

    fun readHandsetInfo(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "device" to Build.DEVICE,
        "android_release" to Build.VERSION.RELEASE,
        "sdk_int" to Build.VERSION.SDK_INT,
    )
}
