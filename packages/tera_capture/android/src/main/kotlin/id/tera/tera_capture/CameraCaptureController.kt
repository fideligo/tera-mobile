package id.tera.tera_capture

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import java.util.concurrent.atomic.AtomicLong

/**
 * Camera2 capture configured the way a PPG measurement needs it (BUILD_SPEC 6.4).
 *
 * Torch on, auto-exposure / auto-white-balance / auto-focus all locked, smallest adequate YUV
 * output. Every frame is reduced to a single region-of-interest mean **here, in native code**,
 * and only that number is handed to Dart.
 *
 * That is invariant 2 expressed in the architecture rather than in a rule: there is no path by
 * which a frame reaches the Dart side, because [ImageReader] images are closed in this file
 * before the callback returns. Nothing above this layer could persist a frame if it wanted to.
 */
internal class CameraCaptureController(
    private val context: Context,
    private val onFrame: (
        timestampNanos: Long,
        roiMean: Double,
        processingNanos: Long,
        frameNumber: Long,
        realtimeAtDeliveryNanos: Long,
        uptimeAtDeliveryNanos: Long,
    ) -> Unit,
    private val onError: (String) -> Unit,
) {
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    private var activeSize: Size? = null
    private var activeMinFrameDurationNanos: Long = 0
    private val frameCounter = AtomicLong(0)

    private val cameraManager: CameraManager
        get() = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    fun activeSizeMap(): Map<String, Any?>? {
        val size = activeSize ?: return null
        return mapOf(
            "width" to size.width,
            "height" to size.height,
            "min_frame_duration_nanos" to activeMinFrameDurationNanos,
        )
    }

    @SuppressLint("MissingPermission") // the caller checks CAMERA before invoking this
    fun start(config: CaptureConfiguration) {
        if (cameraDevice != null) return

        val reader = CameraCharacteristicsReader(context)
        val cameraId = reader.findRearCameraId()
            ?: throw CaptureError("no_rear_camera", "this device reports no rear-facing camera")

        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val configMap = characteristics.get(
            CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP
        ) ?: throw CaptureError(
            "no_stream_configuration",
            "camera $cameraId reports no stream configuration map"
        )

        val sizes = (configMap.getOutputSizes(ImageFormat.YUV_420_888) ?: emptyArray())
            .sortedBy { it.width * it.height }
        if (sizes.isEmpty()) {
            throw CaptureError(
                "no_yuv_output",
                "camera $cameraId offers no YUV_420_888 output size"
            )
        }

        val size = if (config.preferredWidth != null && config.preferredHeight != null) {
            sizes.firstOrNull {
                it.width == config.preferredWidth && it.height == config.preferredHeight
            } ?: sizes.first()
        } else {
            sizes.first()
        }
        activeSize = size
        activeMinFrameDurationNanos =
            configMap.getOutputMinFrameDuration(ImageFormat.YUV_420_888, size)

        startBackgroundThread()

        // maxImages = 2: enough to avoid stalling the producer, few enough that a slow consumer
        // shows up as dropped frames rather than as latency. Dropped frames are what we are
        // trying to measure; hidden latency would falsify the result.
        imageReader = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
            .apply {
                setOnImageAvailableListener(
                    { readerInstance -> consumeFrame(readerInstance, config.roiFraction) },
                    backgroundHandler,
                )
            }

        cameraManager.openCamera(
            cameraId,
            object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    cameraDevice = device
                    try {
                        createSession(device, characteristics, config)
                    } catch (e: Exception) {
                        onError("could not configure capture session: ${e.message}")
                    }
                }

                override fun onDisconnected(device: CameraDevice) {
                    device.close()
                    cameraDevice = null
                    onError("camera disconnected")
                }

                override fun onError(device: CameraDevice, error: Int) {
                    device.close()
                    cameraDevice = null
                    onError("camera error $error")
                }
            },
            backgroundHandler,
        )
    }

    private fun createSession(
        device: CameraDevice,
        characteristics: CameraCharacteristics,
        config: CaptureConfiguration,
    ) {
        val surface = imageReader?.surface ?: return

        @Suppress("DEPRECATION") // createCaptureSession(List, ...) is the API available at minSdk 26
        device.createCaptureSession(
            listOf(surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    try {
                        val request = buildRequest(device, surface, characteristics, config)
                        session.setRepeatingRequest(request, null, backgroundHandler)
                    } catch (e: Exception) {
                        onError("could not start repeating request: ${e.message}")
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    onError("camera rejected the capture session configuration")
                }
            },
            backgroundHandler,
        )
    }

    /**
     * The capture request.
     *
     * Every lock here exists for the same reason: the measurement reads frame-to-frame changes
     * in brightness, so anything that changes brightness on its own destroys the signal. An
     * unlocked auto-exposure would compensate for the pulse and cancel out the thing being
     * measured.
     */
    private fun buildRequest(
        device: CameraDevice,
        surface: android.view.Surface,
        characteristics: CameraCharacteristics,
        config: CaptureConfiguration,
    ): CaptureRequest {
        val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        builder.addTarget(surface)

        if (config.torchOn) {
            builder.set(CaptureRequest.FLASH_MODE, CameraMetadata.FLASH_MODE_TORCH)
            builder.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
        }

        if (config.lockAutoExposure &&
            characteristics.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true
        ) {
            builder.set(CaptureRequest.CONTROL_AE_LOCK, true)
        }

        if (config.lockAutoWhiteBalance &&
            characteristics.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true
        ) {
            builder.set(CaptureRequest.CONTROL_AWB_LOCK, true)
        }

        if (config.lockAutoFocus) {
            // OFF, not AUTO with a lock: a fingertip is flush against the lens, so there is
            // nothing to focus on and an autofocus sweep would modulate the image while it hunts.
            builder.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            val minFocus = characteristics.get(
                CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE
            )
            if (minFocus != null && minFocus > 0f) {
                builder.set(CaptureRequest.LENS_FOCUS_DISTANCE, minFocus)
            }
        }

        // Nothing may resample, stabilise or denoise the frames — each would alter the intensity
        // series in ways that look like signal.
        builder.set(
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
            CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
        )
        builder.set(CaptureRequest.NOISE_REDUCTION_MODE, CameraMetadata.NOISE_REDUCTION_MODE_OFF)
        builder.set(CaptureRequest.CONTROL_AE_ANTIBANDING_MODE, CameraMetadata.CONTROL_AE_ANTIBANDING_MODE_OFF)

        // Ask for the fastest frame rate the device advertises. What is actually delivered is
        // what the profiler measures — BUILD_SPEC 6.1's rule applies to the camera too.
        val fpsRanges = characteristics.get(
            CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
        )
        fpsRanges?.maxByOrNull { it.upper }?.let {
            builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it)
        }

        return builder.build()
    }

    /**
     * Reduce one frame to one number, and close it.
     *
     * The image is closed in a `finally` before this returns. Invariant 2 holds structurally:
     * there is no reference to frame data outside this method's scope.
     */
    private fun consumeFrame(reader: ImageReader, roiFraction: Double) {
        // Both clocks first, back to back, before anything else in this callback. They are the
        // reference against which image.timestamp's *basis* is established: a frame timestamp
        // must sit a plausible pipeline latency behind whichever clock it is expressed in, and
        // implausibly far behind the other. Reading them after the ROI computation would fold
        // that work into the comparison.
        val realtimeAtDelivery = Clocks.realtimeNanos()
        val uptimeAtDelivery = Clocks.uptimeNanos()

        var image: Image? = null
        try {
            image = reader.acquireLatestImage() ?: return

            val startNanos = System.nanoTime()
            val roiMean = RoiProcessor.meanLuminance(image, roiFraction)
            val processingNanos = System.nanoTime() - startNanos

            // image.timestamp is the hardware timestamp, in the base named by
            // SENSOR_INFO_TIMESTAMP_SOURCE — *declared*. Whether it really is in that base is
            // checked by the consumer against the two clock readings above. Not a value taken
            // when this callback ran, which would measure the scheduler rather than the camera.
            onFrame(
                image.timestamp,
                roiMean,
                processingNanos,
                frameCounter.incrementAndGet(),
                realtimeAtDelivery,
                uptimeAtDelivery,
            )
        } catch (e: IllegalStateException) {
            // acquireLatestImage throws when the reader has been closed mid-teardown. Not an
            // error worth reporting; the run is already ending.
        } catch (e: Exception) {
            onError("frame processing failed: ${e.message}")
        } finally {
            image?.close()
        }
    }

    fun stop() {
        try {
            captureSession?.stopRepeating()
        } catch (e: Exception) {
            // The session may already be gone; teardown continues regardless.
        }
        captureSession?.close()
        captureSession = null
        cameraDevice?.close()
        cameraDevice = null
        imageReader?.close()
        imageReader = null
        activeSize = null
        frameCounter.set(0)
        stopBackgroundThread()
    }

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("tera-capture-camera").also {
            it.start()
            backgroundHandler = Handler(it.looper)
        }
    }

    private fun stopBackgroundThread() {
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

/** Capture parameters, parsed from the Dart side. */
internal data class CaptureConfiguration(
    val roiFraction: Double,
    val lockAutoExposure: Boolean,
    val lockAutoWhiteBalance: Boolean,
    val lockAutoFocus: Boolean,
    val torchOn: Boolean,
    val preferredWidth: Int?,
    val preferredHeight: Int?,
) {
    companion object {
        fun fromMap(raw: Map<*, *>?): CaptureConfiguration = CaptureConfiguration(
            roiFraction = (raw?.get("roi_fraction") as? Number)?.toDouble() ?: 0.4,
            lockAutoExposure = raw?.get("lock_ae") as? Boolean ?: true,
            lockAutoWhiteBalance = raw?.get("lock_awb") as? Boolean ?: true,
            lockAutoFocus = raw?.get("lock_af") as? Boolean ?: true,
            torchOn = raw?.get("torch_on") as? Boolean ?: true,
            preferredWidth = (raw?.get("yuv_width") as? Number)?.toInt(),
            preferredHeight = (raw?.get("yuv_height") as? Number)?.toInt(),
        )
    }
}
