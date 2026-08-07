package id.tera.tera_capture

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** A failure with a code the Dart side can act on and a message a human can read. */
internal class CaptureError(val code: String, override val message: String) : Exception(message)

/**
 * Channel wiring for the Tera capture layer.
 *
 * This class does routing and nothing else — permission handling, argument parsing and lifecycle.
 * The measurements live in [CameraCharacteristicsReader], [CameraCaptureController],
 * [AccelerometerRecorder] and [DeviceContextReader], each of which is usable on its own. The
 * patient capture app will consume the same classes without going near this file.
 */
class TeraCapturePlugin :
    FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {

    private lateinit var methodChannel: MethodChannel
    private lateinit var accelerometerChannel: EventChannel
    private lateinit var frameChannel: EventChannel
    private lateinit var context: Context

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private var accelerometerRecorder: AccelerometerRecorder? = null
    private var cameraController: CameraCaptureController? = null
    private var accelerometerSink: EventChannel.EventSink? = null
    private var frameSink: EventChannel.EventSink? = null

    /** Event sinks must be touched on the main thread; the sensor and camera run on their own. */
    private val mainHandler = Handler(Looper.getMainLooper())

    private companion object {
        const val CAMERA_PERMISSION_REQUEST = 0x7e2a
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, "id.tera.capture/methods")
        methodChannel.setMethodCallHandler(this)

        accelerometerChannel = EventChannel(binding.binaryMessenger, "id.tera.capture/accelerometer")
        accelerometerChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                accelerometerSink = events
            }

            override fun onCancel(arguments: Any?) {
                accelerometerSink = null
            }
        })

        frameChannel = EventChannel(binding.binaryMessenger, "id.tera.capture/frames")
        frameChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                frameSink = events
            }

            override fun onCancel(arguments: Any?) {
                frameSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Leaving the camera or the sensor running past engine teardown would hold the torch on
        // and drain the handset, which on a measurement day is worse than an error.
        stopEverything()
        methodChannel.setMethodCallHandler(null)
        accelerometerChannel.setStreamHandler(null)
        frameChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "readHandsetInfo" -> result.success(DeviceContextReader(context).readHandsetInfo())
                "readAccelerometerInfo" -> result.success(recorder().readInfo())
                "readCameraCapabilities" ->
                    result.success(CameraCharacteristicsReader(context).read())
                "readDeviceContext" -> result.success(DeviceContextReader(context).read())
                "readClockOffset" -> result.success(DeviceContextReader(context).readClockOffset())
                "ensureCameraPermission" -> ensureCameraPermission(result)
                "startAccelerometer" -> startAccelerometer(result)
                "stopAccelerometer" -> stopAccelerometer(result)
                "startCamera" -> startCamera(call, result)
                "stopCamera" -> stopCamera(result)
                "activeYuvSize" -> result.success(cameraController?.activeSizeMap())
                else -> result.notImplemented()
            }
        } catch (e: CaptureError) {
            result.error(e.code, e.message, null)
        } catch (e: SecurityException) {
            result.error("permission_denied", e.message ?: "permission denied", null)
        } catch (e: Exception) {
            result.error("capture_failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    // ------------------------------------------------------------------ accelerometer

    private fun recorder(): AccelerometerRecorder =
        accelerometerRecorder ?: AccelerometerRecorder(context) {
            timestamp, x, y, z, realtimeAtDelivery, uptimeAtDelivery ->
            mainHandler.post {
                accelerometerSink?.success(
                    listOf(timestamp, x, y, z, realtimeAtDelivery, uptimeAtDelivery)
                )
            }
        }.also { accelerometerRecorder = it }

    private fun startAccelerometer(result: MethodChannel.Result) {
        recorder().start()
        result.success(true)
    }

    private fun stopAccelerometer(result: MethodChannel.Result) {
        accelerometerRecorder?.stop()
        result.success(true)
    }

    // ------------------------------------------------------------------ camera

    private fun startCamera(call: MethodCall, result: MethodChannel.Result) {
        if (!hasCameraPermission()) {
            result.error(
                "permission_denied",
                "camera permission has not been granted",
                null,
            )
            return
        }

        val config = CaptureConfiguration.fromMap(call.arguments as? Map<*, *>)

        val controller = CameraCaptureController(
            context = context,
            onFrame = {
                timestamp, roiMean, processingNanos, frameNumber, realtimeAtDelivery, uptimeAtDelivery ->
                mainHandler.post {
                    frameSink?.success(
                        listOf(
                            timestamp,
                            roiMean,
                            processingNanos,
                            frameNumber,
                            realtimeAtDelivery,
                            uptimeAtDelivery,
                        )
                    )
                }
            },
            onError = { message ->
                mainHandler.post {
                    frameSink?.error("camera_failed", message, null)
                }
            },
        )
        cameraController = controller
        controller.start(config)
        result.success(true)
    }

    private fun stopCamera(result: MethodChannel.Result) {
        cameraController?.stop()
        cameraController = null
        result.success(true)
    }

    // ------------------------------------------------------------------ permissions

    private fun hasCameraPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun ensureCameraPermission(result: MethodChannel.Result) {
        if (hasCameraPermission()) {
            result.success(true)
            return
        }

        val currentActivity = activity
        if (currentActivity == null) {
            result.error(
                "no_activity",
                "cannot request camera permission without an attached activity",
                null,
            )
            return
        }

        if (pendingPermissionResult != null) {
            result.error("already_requesting", "a permission request is already in flight", null)
            return
        }

        pendingPermissionResult = result
        currentActivity.requestPermissions(
            arrayOf(Manifest.permission.CAMERA),
            CAMERA_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != CAMERA_PERMISSION_REQUEST) return false

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        return true
    }

    // ------------------------------------------------------------------ lifecycle

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        // A capture that outlives its activity keeps the torch lit with nothing on screen.
        stopEverything()
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    private fun stopEverything() {
        try {
            cameraController?.stop()
        } catch (e: Exception) {
            // teardown is best-effort; there is nobody left to report to
        }
        cameraController = null
        try {
            accelerometerRecorder?.stop()
        } catch (e: Exception) {
            // as above
        }
        accelerometerRecorder = null
    }
}
