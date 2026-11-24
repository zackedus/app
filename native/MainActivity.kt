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
        settingsChannel?.setMethodCallHandler(null)
        worker.execute { detector?.close() }
        worker.shutdown()
        super.onDestroy()
    }
}
