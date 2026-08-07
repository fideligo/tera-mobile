package id.tera.tera_capture

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.util.Size

/**
 * Reads what `CameraCharacteristics` says about the rear camera (BUILD_SPEC 6.3).
 *
 * This exists as a MethodChannel handler because the standard camera plugin does not expose any
 * of it. Every value here comes from the platform; nothing is inferred, defaulted or guessed —
 * a characteristic the device does not report comes back as `unknown`, never as a plausible
 * value (invariant 9).
 */
internal class CameraCharacteristicsReader(private val context: Context) {

    private val cameraManager: CameraManager
        get() = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    /**
     * The rear-facing camera, which is the one a fingertip is pressed against.
     *
     * Returns null when there is no back camera at all, which is a real answer for a device that
     * cannot run Tera rather than a reason to fall back to the front camera.
     */
    fun findRearCameraId(): String? {
        for (id in cameraManager.cameraIdList) {
            val facing = cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_BACK) return id
        }
        return null
    }

    fun read(): Map<String, Any?> {
        val cameraId = findRearCameraId()
            ?: throw CaptureError("no_rear_camera", "this device reports no rear-facing camera")

        val characteristics = cameraManager.getCameraCharacteristics(cameraId)

        // INFO_SUPPORTED_HARDWARE_LEVEL. A LEGACY device cannot lock exposure reliably, and
        // unlocked auto-exposure corrupts the very brightness series the measurement reads.
        val hardwareLevel = when (
            characteristics.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
        ) {
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level_3"
            CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "external"
            else -> "unknown"
        }

        // REQUEST_AVAILABLE_CAPABILITIES containing MANUAL_SENSOR. Without it, exposure time and
        // gain cannot be pinned for the duration of a capture.
        val capabilities =
            characteristics.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                ?: IntArray(0)
        val hasManualSensor = capabilities.contains(
            CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR
        )

        // SENSOR_INFO_TIMESTAMP_SOURCE. REALTIME means camera frame timestamps share a base with
        // SystemClock.elapsedRealtimeNanos(), which is what the accelerometer reports in. UNKNOWN
        // means the two signals must be aligned through an inferred offset — precisely the error
        // a transit-time measurement is most sensitive to.
        val timestampSource = when (
            characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
        ) {
            CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> "realtime"
            CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN -> "unknown"
            else -> "unknown"
        }

        val configMap = characteristics.get(
            CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP
        ) ?: throw CaptureError(
            "no_stream_configuration",
            "camera $cameraId reports no stream configuration map"
        )

        // Every YUV_420_888 output size with its minimum frame duration, ascending by pixel
        // count. The smallest is what a capture uses: a fingertip against the lens has no detail
        // to resolve, and every extra pixel is time inside the per-frame budget.
        val yuvSizes = (configMap.getOutputSizes(ImageFormat.YUV_420_888) ?: emptyArray<Size>())
            .sortedBy { it.width * it.height }
            .map { size ->
                mapOf(
                    "width" to size.width,
                    "height" to size.height,
                    "min_frame_duration_nanos" to
                        configMap.getOutputMinFrameDuration(ImageFormat.YUV_420_888, size),
                )
            }

        val availableAeModes =
            characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES) ?: IntArray(0)

        return mapOf(
            "camera_id" to cameraId,
            "hardware_level" to hardwareLevel,
            "has_manual_sensor" to hasManualSensor,
            "timestamp_source" to timestampSource,
            "yuv_sizes" to yuvSizes,
            "has_flash" to
                (characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true),
            "supports_ae_lock" to
                (characteristics.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true),
            "supports_awb_lock" to
                (characteristics.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true),
            "available_ae_mode_count" to availableAeModes.size,
        )
    }
}
