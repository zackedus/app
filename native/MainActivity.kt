package id.rancangpro.object_detection

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.RectF
import kotlin.math.roundToInt
import android.graphics.YuvImage
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.tensorflow.lite.support.image.TensorImage
import org.tensorflow.lite.task.vision.detector.ObjectDetector
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var detector: ObjectDetector? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "object_detection/detector"
        ).also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                if (call.method != "detect" && call.method != "learnPhoto") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                worker.execute {
                    try {
                        val detections = if (call.method == "detect") detect(call) else learnPhoto(call)
                        runOnUiThread { result.success(detections) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("DETECT", error.message, null) }
                    }
                }
            }
        }
    }

    private fun detect(call: MethodCall): List<Map<String, Any>> {
        val bytes = requireNotNull(call.argument<ByteArray>("bytes"))
        val width = requireNotNull(call.argument<Int>("width"))
        val height = requireNotNull(call.argument<Int>("height"))
        val rotation = requireNotNull(call.argument<Int>("rotation"))
        val model = detector ?: ObjectDetector.createFromFileAndOptions(
            applicationContext,
            "model.tflite",
            ObjectDetector.ObjectDetectorOptions.builder()
                .setMaxResults(8)
                .setScoreThreshold(0.5f)
                .build()
        ).also { detector = it }

        val jpeg = ByteArrayOutputStream()
        val yuv = YuvImage(bytes, ImageFormat.NV21, width, height, null)
        check(yuv.compressToJpeg(Rect(0, 0, width, height), 85, jpeg))
        val encoded = jpeg.toByteArray()
        val bitmap = checkNotNull(BitmapFactory.decodeByteArray(encoded, 0, encoded.size))
        try {
            val upright = Bitmap.createBitmap(
                bitmap, 0, 0, bitmap.width, bitmap.height,
                Matrix().apply { postRotate(rotation.toFloat()) }, true
            )
            try {
                return model.detect(TensorImage.fromBitmap(upright)).mapNotNull { detection ->
                    val category = detection.categories.maxByOrNull { it.score }
                        ?: return@mapNotNull null
                    val box = detection.boundingBox
                    mapOf(
                        "label" to category.label,
                        "appearance" to appearance(upright, box),
                        "score" to category.score.toDouble(),
                        "left" to box.left.toDouble() / upright.width,
                        "top" to box.top.toDouble() / upright.height,
                        "right" to box.right.toDouble() / upright.width,
                        "bottom" to box.bottom.toDouble() / upright.height
                    )
                }
            } finally {
                if (upright !== bitmap) upright.recycle()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun learnPhoto(call: MethodCall): List<List<Double>> {
        val path = requireNotNull(call.argument<String>("path"))
        require(path.startsWith(filesDir.parentFile!!.absolutePath + "/"))
        val boxes = requireNotNull(call.argument<List<List<Number>>>("boxes"))
        val photo = if (android.os.Build.VERSION.SDK_INT >= 28) {
            android.graphics.ImageDecoder.decodeBitmap(
                android.graphics.ImageDecoder.createSource(java.io.File(path))
            ) { decoder, _, _ ->
                decoder.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } else {
            checkNotNull(BitmapFactory.decodeFile(path))
        }
        try {
            return boxes.map { box ->
                appearance(photo, RectF(
                    box[0].toFloat() * photo.width,
                    box[1].toFloat() * photo.height,
                    box[2].toFloat() * photo.width,
                    box[3].toFloat() * photo.height
                ))
            }
        } finally {
            photo.recycle()
        }
    }

    private fun appearance(bitmap: Bitmap, box: RectF): List<Double> {
        val features = ArrayList<Double>(48)
        for (row in 0 until 4) {
            for (column in 0 until 4) {
                val colors = DoubleArray(3)
                for (y in 0 until 3) {
                    for (x in 0 until 3) {
                        val px = (box.left + (column + (x + 0.5) / 3) * box.width() / 4)
                            .roundToInt().coerceIn(0, bitmap.width - 1)
                        val py = (box.top + (row + (y + 0.5) / 3) * box.height() / 4)
                            .roundToInt().coerceIn(0, bitmap.height - 1)
                        val color = bitmap.getPixel(px, py)
                        colors[0] += android.graphics.Color.red(color).toDouble()
                        colors[1] += android.graphics.Color.green(color).toDouble()
                        colors[2] += android.graphics.Color.blue(color).toDouble()
                    }
                }
                colors.forEach { features.add(it / 2295.0) }
            }
        }
        return features
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        worker.execute { detector?.close() }
        worker.shutdown()
        super.onDestroy()
    }
}
