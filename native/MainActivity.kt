package id.rancangpro.object_detection

import android.graphics.Bitmap
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.RectF
import kotlin.math.roundToInt
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.PI
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
    private var settingsChannel: MethodChannel? = null

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
        settingsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "object_detection/openrouter_settings"
        ).also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "load", "save" -> worker.execute {
                        try {
                            val value = if (call.method == "load") loadSettings() else {
                                saveSettings(
                                    requireNotNull(call.argument<String>("token")),
                                    requireNotNull(call.argument<String>("model"))
                                )
                                null
                            }
                            runOnUiThread { result.success(value) }
                        } catch (_: Exception) {
                            runOnUiThread {
                                result.error("SETTINGS_STORAGE", "Pengaturan tidak bisa diakses.", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun settingsKey(create: Boolean): SecretKey {
        val alias = "openrouter_settings_v1"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val stored = store.getKey(alias, null)
        if (stored is SecretKey) return stored
        check(create)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(KeyGenParameterSpec.Builder(
                    alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build())
            }.generateKey()
    }

    private fun loadSettings(): Map<String, String> {
        val preferences = getSharedPreferences("openrouter_settings", MODE_PRIVATE)
        val model = preferences.getString("model", "") ?: ""
        val ciphertext = preferences.getString("token", null)
        val token = if (ciphertext == null) "" else try {
            val iv = Base64.decode(requireNotNull(preferences.getString("iv", null)), Base64.NO_WRAP)
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, settingsKey(false), GCMParameterSpec(128, iv))
                String(doFinal(Base64.decode(ciphertext, Base64.NO_WRAP)), Charsets.UTF_8)
            }
        } catch (_: Exception) {
            // A restored installation may lack the original Android Keystore key.
            ""
        }
        return mapOf("token" to token, "model" to model)
    }

    private fun saveSettings(token: String, model: String) {
        val editor = getSharedPreferences("openrouter_settings", MODE_PRIVATE)
            .edit().putString("model", model)
        if (token.isEmpty()) {
            editor.remove("token").remove("iv")
        } else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, settingsKey(true))
            editor.putString("token", Base64.encodeToString(
                cipher.doFinal(token.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP
            )).putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
        }
        check(editor.commit())
    }

    private fun detect(call: MethodCall): List<Map<String, Any>> {
        val bytes = requireNotNull(call.argument<ByteArray>("bytes"))
        val width = requireNotNull(call.argument<Int>("width"))
        val height = requireNotNull(call.argument<Int>("height"))
        val rotation = requireNotNull(call.argument<Int>("rotation"))
        val focus = call.argument<Boolean>("focus") == true
        val model = detector ?: ObjectDetector.createFromFileAndOptions(
            applicationContext,
            "model.tflite",
            ObjectDetector.ObjectDetectorOptions.builder()
                .setMaxResults(16)
                .setScoreThreshold(0.20f)
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
                if (focus) {
                    val box = RectF(
                        upright.width * .2f, upright.height * .3f,
                        upright.width * .8f, upright.height * .7f
                    )
                    return listOf(candidate(upright, box, "", 0.0))
                }
                return model.detect(TensorImage.fromBitmap(upright)).mapNotNull { detection ->
                    val category = detection.categories.maxByOrNull { it.score }
                        ?: return@mapNotNull null
                    candidate(upright, detection.boundingBox, category.label, category.score.toDouble())
                }
            } finally {
                if (upright !== bitmap) upright.recycle()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun candidate(
        bitmap: Bitmap, box: RectF, label: String, score: Double
    ): Map<String, Any> = mapOf(
        "label" to label,
        "appearance" to appearance(bitmap, box),
        "score" to score,
        "left" to box.left.toDouble() / bitmap.width,
        "top" to box.top.toDouble() / bitmap.height,
        "right" to box.right.toDouble() / bitmap.width,
        "bottom" to box.bottom.toDouble() / bitmap.height
    )

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
        val size = 24
        val luminance = DoubleArray(size * size)
        val colors = DoubleArray(24)
        for (y in 0 until size) {
            for (x in 0 until size) {
                val px = (box.left + (x + 0.5) * box.width() / size)
                    .roundToInt().coerceIn(0, bitmap.width - 1)
                val py = (box.top + (y + 0.5) * box.height() / size)
                    .roundToInt().coerceIn(0, bitmap.height - 1)
                val color = bitmap.getPixel(px, py)
                val red = android.graphics.Color.red(color)
                val green = android.graphics.Color.green(color)
                val blue = android.graphics.Color.blue(color)
                luminance[y * size + x] = .299 * red + .587 * green + .114 * blue
                val total = red + green + blue
                if (total >= 24) {
                    addColorVote(colors, 0, red.toDouble() / total)
                    addColorVote(colors, 8, green.toDouble() / total)
                    addColorVote(colors, 16, blue.toDouble() / total)
                }
            }
        }
        // Subtract a local mean to suppress shadows and gradual lighting changes.
        val detail = luminance.copyOf()
        for (y in 2 until size - 2) {
            for (x in 2 until size - 2) {
                var sum = 0.0
                for (dy in -2..2) {
                    for (dx in -2..2) sum += luminance[(y + dy) * size + x + dx]
                }
                detail[y * size + x] -= sum / 25
            }
        }
        val edges = DoubleArray(32)
        for (y in 3 until size - 3) {
            for (x in 3 until size - 3) {
                val index = y * size + x
                val dx = detail[index + 1] - detail[index - 1]
                val dy = detail[index + size] - detail[index - size]
                val magnitude = hypot(dx, dy)
                if (magnitude < 2) continue
                val orientation = ((atan2(dy, dx) + PI) % PI) * 8 / PI
                val bin = orientation.toInt().coerceIn(0, 7)
                val fraction = (orientation - bin).coerceIn(0.0, 1.0)
                val cell = (y / (size / 2)) * 2 + x / (size / 2)
                edges[cell * 8 + bin] += magnitude * (1 - fraction)
                edges[cell * 8 + (bin + 1) % 8] += magnitude * fraction
            }
        }
        val edgeSum = edges.sum().coerceAtLeast(1.0)
        val colorSum = colors.sum().coerceAtLeast(1.0)
        return edges.map { it / edgeSum } + colors.map { it / colorSum }
    }

    private fun addColorVote(histogram: DoubleArray, offset: Int, value: Double) {
        val position = value * 7
        val bin = position.toInt().coerceIn(0, 7)
        val fraction = position - bin
        histogram[offset + bin] += 1 - fraction
        histogram[offset + (bin + 1).coerceAtMost(7)] += fraction
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        settingsChannel?.setMethodCallHandler(null)
        worker.execute { detector?.close() }
        worker.shutdown()
        super.onDestroy()
    }
}
