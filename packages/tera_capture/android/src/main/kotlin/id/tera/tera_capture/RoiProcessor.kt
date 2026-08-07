package id.tera.tera_capture

import android.media.Image

/**
 * Reduces a YUV_420_888 frame to the mean luminance of a centred region.
 *
 * This is the whole of the per-frame work, and BUILD_SPEC 6.7 asks how long it takes on real
 * hardware — so it is written to be fast and to be timed honestly: only the Y plane is touched,
 * the loop respects row stride and pixel stride rather than assuming a packed layout, and
 * nothing is allocated per frame.
 *
 * Only the Y (luminance) plane matters. The signal is a change in how much light returns
 * through the fingertip, which is a brightness change; chrominance carries nothing useful and
 * reading it would double the work inside the frame budget.
 */
internal object RoiProcessor {

    /**
     * Mean luminance over a centred square whose side is [roiFraction] of the smaller frame
     * dimension.
     *
     * A fingertip covers the entire lens, so the centre is representative and a smaller region
     * costs proportionally less time. Returns the mean in the range 0..255.
     */
    fun meanLuminance(image: Image, roiFraction: Double): Double {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride

        val width = image.width
        val height = image.height

        val side = (minOf(width, height) * roiFraction).toInt().coerceAtLeast(1)
        val startX = ((width - side) / 2).coerceAtLeast(0)
        val startY = ((height - side) / 2).coerceAtLeast(0)
        val endX = (startX + side).coerceAtMost(width)
        val endY = (startY + side).coerceAtMost(height)

        var total = 0L
        var count = 0

        for (y in startY until endY) {
            var index = y * rowStride + startX * pixelStride
            for (x in startX until endX) {
                // Y is unsigned; Java bytes are signed, hence the mask.
                total += (buffer.get(index).toInt() and 0xFF)
                index += pixelStride
                count++
            }
        }

        return if (count == 0) 0.0 else total.toDouble() / count
    }
}
