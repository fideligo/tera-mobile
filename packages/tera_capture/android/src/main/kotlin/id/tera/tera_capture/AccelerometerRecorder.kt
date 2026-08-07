package id.tera.tera_capture

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread

/**
 * Accelerometer capture at the fastest rate the device will actually deliver (BUILD_SPEC 6.1).
 *
 * Two details carry the whole measurement:
 *
 *  * **Batching is disabled** — `maxReportLatencyUs = 0`. With batching on, the platform is free
 *    to buffer samples and deliver them in bursts. The sample *timestamps* stay correct, but any
 *    latency measurement would be meaningless and the delivery pattern would not resemble what a
 *    real-time capture sees.
 *  * **Timestamps come from `SensorEvent.timestamp`**, never from when the callback ran.
 *    Callback time in a garbage-collected runtime measures the runtime.
 *
 * The requested rate is `SENSOR_DELAY_FASTEST`, and what arrives is measured rather than assumed
 * — which is the point of the exercise.
 */
internal class AccelerometerRecorder(
    private val context: Context,
    private val onSample: (
        timestampNanos: Long,
        x: Float,
        y: Float,
        z: Float,
        realtimeAtDeliveryNanos: Long,
        uptimeAtDeliveryNanos: Long,
    ) -> Unit,
) {
    private var sensorManager: SensorManager? = null
    private var sensor: Sensor? = null
    private var listener: SensorEventListener? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private fun manager(): SensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    /**
     * Whether `HIGH_SAMPLING_RATE_SENSORS` is held.
     *
     * BUILD_SPEC 6.2: without the declaration the platform caps sensors at 200 Hz on Android
     * 12+. Below API 31 the permission does not exist and no cap applies, so it is reported as
     * granted — that is the truthful answer to "are rates above 200 Hz available to this app",
     * which is what the field means.
     */
    fun hasHighSamplingRatePermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return context.checkSelfPermission(
            android.Manifest.permission.HIGH_SAMPLING_RATE_SENSORS
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun readInfo(): Map<String, Any?> {
        val accelerometer = manager().getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            ?: throw CaptureError(
                "no_accelerometer",
                "this device reports no accelerometer"
            )

        return mapOf(
            "name" to accelerometer.name,
            "vendor" to accelerometer.vendor,
            // minDelay is the fastest period the sensor *advertises*. BUILD_SPEC 6.1 exists
            // because it frequently is not what gets delivered.
            "min_delay_micros" to accelerometer.minDelay,
            "max_delay_micros" to accelerometer.maxDelay,
            "high_sampling_rate_granted" to hasHighSamplingRatePermission(),
        )
    }

    fun start() {
        if (listener != null) return

        val manager = manager()
        val accelerometer = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            ?: throw CaptureError("no_accelerometer", "this device reports no accelerometer")

        backgroundThread = HandlerThread("tera-capture-accelerometer").also {
            it.start()
            backgroundHandler = Handler(it.looper)
        }

        val sensorListener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                // Both clocks first, back to back. SensorEvent.timestamp is *documented* as
                // elapsedRealtimeNanos, but the documentation is not universally honoured and
                // the consumer checks empirically. Two vDSO reads per sample; negligible next
                // to the channel crossing that follows.
                val realtimeAtDelivery = Clocks.realtimeNanos()
                val uptimeAtDelivery = Clocks.uptimeNanos()
                onSample(
                    event.timestamp,
                    event.values[0],
                    event.values[1],
                    event.values[2],
                    realtimeAtDelivery,
                    uptimeAtDelivery,
                )
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }

        val registered = manager.registerListener(
            sensorListener,
            accelerometer,
            SensorManager.SENSOR_DELAY_FASTEST,
            0, // maxReportLatencyUs = 0 disables batching
            backgroundHandler,
        )

        if (!registered) {
            stop()
            throw CaptureError(
                "sensor_registration_failed",
                "the platform refused to register an accelerometer listener"
            )
        }

        sensorManager = manager
        sensor = accelerometer
        listener = sensorListener
    }

    fun stop() {
        listener?.let { sensorManager?.unregisterListener(it) }
        listener = null
        sensor = null
        sensorManager = null

        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join(1000)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        backgroundThread = null
        backgroundHandler = null
    }
}
