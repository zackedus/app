package id.rancangpro.object_detection

import android.graphics.Bitmap
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imageembedder.ImageEmbedder
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector
import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.math.ceil
import kotlin.math.floor
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.RectF
import kotlin.math.roundToInt
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.PI
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val exportWorker = Executors.newSingleThreadExecutor()
    private var detector: ObjectDetector? = null
    private var customDetector: RfDetrDetector? = null
    private var customChecked = false
    private var customError: String? = null
    private var keptFrame: Bitmap? = null
    private var pendingPick: MethodChannel.Result? = null
    private var pendingLocation: MethodChannel.Result? = null

    private companion object {
        const val REQUEST_PICK = 4101
        const val REQUEST_LOCATION = 4102
    }
    private var embedder: ImageEmbedder? = null
    private var embeddingUnavailable = false
    private var channel: MethodChannel? = null
    private var settingsChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "object_detection/detector"
        ).also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "share" -> {
                        try {
                            sharePhoto(requireNotNull(call.argument<String>("uri")))
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("SHARE", error.message, null)
                        }
                        return@setMethodCallHandler
                    }
                    "pickPhoto" -> {
                        pickPhoto(result)
                        return@setMethodCallHandler
                    }
                    "location" -> {
                        requestLocation(result)
                        return@setMethodCallHandler
                    }
                    "detect", "learnPhoto", "exportDataset", "detectorInfo",
                    "detectPhoto", "saveSnapshot" -> Unit
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                // Export can take a while, so it runs outside the frame worker.
                val executor = if (call.method == "exportDataset") exportWorker else worker
                executor.execute {
                    try {
                        val detections = when (call.method) {
                            "detect" -> detect(call)
                            "learnPhoto" -> learnPhoto(call)
                            "detectorInfo" -> detectorInfo()
                            "detectPhoto" -> detectPhoto(call)
                            "saveSnapshot" -> saveSnapshot(call)
                            else -> exportDataset(call)
                        }
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
        val compareExamples = call.argument<Boolean>("compareExamples") == true
        val keepFrame = call.argument<Boolean>("keepFrame") == true
        require(width > 0 && height > 0 && bytes.size == width * height * 3 / 2)
        val bitmap = nv21ToBitmap(bytes, width, height)
        try {
            val upright = if (rotation % 360 == 0) bitmap else Bitmap.createBitmap(
                bitmap, 0, 0, bitmap.width, bitmap.height,
                Matrix().apply { postRotate(rotation.toFloat()) }, true
            )
            try {
                if (keepFrame) {
                    // Kept as a copy: the frame and its MPImage are recycled below.
                    keptFrame?.recycle()
                    keptFrame = upright.copy(Bitmap.Config.ARGB_8888, false)
                }
                return detectBitmap(upright, focus, compareExamples)
            } finally {
                if (upright !== bitmap) upright.recycle()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun objectDetector(): ObjectDetector = detector ?: ObjectDetector.createFromOptions(
        applicationContext,
        ObjectDetector.ObjectDetectorOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath("model.tflite").build())
            .setRunningMode(RunningMode.IMAGE)
            .setMaxResults(16)
            .setScoreThreshold(0.20f)
            .build()
    ).also { detector = it }

    private fun detectBitmap(
        upright: Bitmap, focus: Boolean, compareExamples: Boolean
    ): List<Map<String, Any>> {
        if (focus) {
            val box = RectF(
                upright.width * .2f, upright.height * .3f,
                upright.width * .8f, upright.height * .7f
            )
            return listOf(candidate(upright, box, "", 0.0, true))
        }
        val custom = customModel()
        if (custom != null) {
            return custom.detect(upright, 0.2f, 16).mapIndexed { index, found ->
                candidate(upright, found.box, found.label, found.score.toDouble(),
                    compareExamples && index < 8)
            }
        }
        // Closing an MPImage may recycle its bitmap, so close it only after all crops.
        val input = BitmapImageBuilder(upright).build()
        try {
            return objectDetector().detect(input).detections().mapNotNull { detection ->
                val category = detection.categories().maxByOrNull { it.score() }
                    ?: return@mapNotNull null
                Triple(detection.boundingBox(), category.categoryName(), category.score())
            }.sortedByDescending { it.third }.mapIndexed { index, (box, label, score) ->
                // The UI shows at most eight boxes, so each of them can match examples.
                candidate(upright, box, label, score.toDouble(), compareExamples && index < 8)
            }
        } finally {
            input.close()
        }
    }

    private fun detectPhoto(call: MethodCall): Map<String, Any> {
        val path = requireNotNull(call.argument<String>("path"))
        requireAppFile(path)
        val compareExamples = call.argument<Boolean>("compareExamples") == true
        val photo = decodePhoto(path)
        val width = photo.width
        val height = photo.height
        try {
            return mapOf(
                "width" to width,
                "height" to height,
                "detections" to detectBitmap(photo, false, compareExamples),
            )
        } finally {
            photo.recycle()
        }
    }

    // Draws the boxes the UI shows onto the kept camera frame or a photo and saves it.
    private fun saveSnapshot(call: MethodCall): Map<String, String> {
        val path = call.argument<String>("path")
        val boxes = requireNotNull(call.argument<List<List<Number>>>("boxes"))
        val labels = requireNotNull(call.argument<List<String>>("labels"))
        val caption = call.argument<String>("caption").orEmpty()
        val source = if (path != null) {
            requireAppFile(path)
            decodePhoto(path)
        } else {
            checkNotNull(keptFrame) { "Frame kamera belum tersedia" }.also { keptFrame = null }
        }
        try {
            val annotated = PhotoTools.annotate(source, boxes, labels, caption)
            try {
                val (location, uri) = PhotoTools.saveJpeg(
                    applicationContext, annotated, "deteksi_${System.currentTimeMillis()}.jpg"
                )
                return mapOf("location" to location, "uri" to (uri?.toString() ?: ""))
            } finally {
                annotated.recycle()
            }
        } finally {
            source.recycle()
        }
    }

    private fun sharePhoto(uri: String) {
        val intent = Intent(Intent.ACTION_SEND)
            .setType("image/jpeg")
            .putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(intent, "Bagikan foto deteksi"))
    }

    private fun pickPhoto(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("BUSY", "Pemilih foto sedang terbuka", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_GET_CONTENT)
            .setType("image/*")
            .addCategory(Intent.CATEGORY_OPENABLE)
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(Intent.createChooser(intent, "Pilih foto"), REQUEST_PICK)
        } catch (error: Exception) {
            pendingPick = null
            result.error("PICK", error.message, null)
        }
    }

    @Deprecated("Uses the platform activity result callback")
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        worker.execute {
            try {
                val (path, width, height) = PhotoTools.importPicked(applicationContext, uri)
                runOnUiThread {
                    result.success(mapOf("path" to path, "width" to width, "height" to height))
                }
            } catch (error: Exception) {
                runOnUiThread { result.error("PICK", error.message, null) }
            }
        }
    }

    private fun hasLocationPermission() =
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun requestLocation(result: MethodChannel.Result) {
        if (hasLocationPermission()) {
            result.success(lastLocation())
            return
        }
        if (pendingLocation != null) {
            result.success(null)
            return
        }
        pendingLocation = result
        requestPermissions(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            REQUEST_LOCATION
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_LOCATION) return
        val result = pendingLocation ?: return
        pendingLocation = null
        result.success(if (hasLocationPermission()) lastLocation() else null)
    }

    // The newest last-known fix from any enabled provider; no waiting for a new fix.
    private fun lastLocation(): Map<String, Any>? = try {
        val manager = getSystemService(LOCATION_SERVICE) as LocationManager
        manager.getProviders(true)
            .mapNotNull { manager.getLastKnownLocation(it) }
            .maxByOrNull { it.time }
            ?.let {
                mapOf(
                    "latitude" to it.latitude,
                    "longitude" to it.longitude,
                    "accuracy" to it.accuracy.toDouble(),
                    "time" to it.time,
                )
            }
    } catch (_: SecurityException) {
        null
    }

    // A fine-tuned RF-DETR model bundled as custom_model.tflite replaces the COCO detector.
    private fun customModel(): RfDetrDetector? {
        if (!customChecked) {
            customChecked = true
            val assetNames = assets.list("")?.toSet() ?: emptySet()
            if ("custom_model.tflite" in assetNames && "custom_model.tflite.rfdetr.json" in assetNames) {
                try {
                    customDetector = RfDetrDetector(
                        applicationContext, "custom_model.tflite", "custom_model.tflite.rfdetr.json"
                    )
                } catch (error: Exception) {
                    // Fall back to the COCO detector and tell the UI why.
                    customError = error.message ?: error.javaClass.simpleName
                }
            }
        }
        return customDetector
    }

    private fun detectorInfo(): Map<String, Any> {
        val custom = customModel()
        return if (custom != null) {
            mapOf("name" to "RF-DETR kustom", "classes" to custom.classNames)
        } else {
            val name = customError?.let { "EfficientDet-Lite0 (COCO) — model kustom gagal: $it" }
                ?: "EfficientDet-Lite0 (COCO)"
            mapOf("name" to name, "classes" to emptyList<String>())
        }
    }

    // Converts an NV21 camera frame directly to ARGB (BT.601), avoiding a lossy JPEG round trip.
    private fun nv21ToBitmap(data: ByteArray, width: Int, height: Int): Bitmap {
        val frameSize = width * height
        val argb = IntArray(frameSize)
        var yIndex = 0
        for (row in 0 until height) {
            var uvIndex = frameSize + (row shr 1) * width
            var u = 0
            var v = 0
            for (column in 0 until width) {
                val luma = ((data[yIndex].toInt() and 0xff) - 16).coerceAtLeast(0)
                if (column and 1 == 0) {
                    v = (data[uvIndex++].toInt() and 0xff) - 128
                    u = (data[uvIndex++].toInt() and 0xff) - 128
                }
                val scaled = 1192 * luma
                val red = (scaled + 1634 * v).coerceIn(0, 262143)
                val green = (scaled - 833 * v - 400 * u).coerceIn(0, 262143)
                val blue = (scaled + 2066 * u).coerceIn(0, 262143)
                argb[yIndex] = -0x1000000 or
                    ((red shl 6) and 0xff0000) or
                    ((green shr 2) and 0xff00) or
                    ((blue shr 10) and 0xff)
                yIndex++
            }
        }
        return Bitmap.createBitmap(argb, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun candidate(
        bitmap: Bitmap, box: RectF, label: String, score: Double, useEmbedding: Boolean
    ): Map<String, Any> = mapOf(
        "label" to label,
        "appearance" to appearance(bitmap, box, useEmbedding),
        "score" to score,
        "left" to box.left.toDouble() / bitmap.width,
        "top" to box.top.toDouble() / bitmap.height,
        "right" to box.right.toDouble() / bitmap.width,
        "bottom" to box.bottom.toDouble() / bitmap.height
    )

    private fun learnPhoto(call: MethodCall): List<List<Double>> {
        val path = requireNotNull(call.argument<String>("path"))
        requireAppFile(path)
        val boxes = requireNotNull(call.argument<List<List<Number>>>("boxes"))
        val photo = decodePhoto(path)
        try {
            return boxes.map { box ->
                appearance(photo, RectF(
                    box[0].toFloat() * photo.width,
                    box[1].toFloat() * photo.height,
                    box[2].toFloat() * photo.width,
                    box[3].toFloat() * photo.height
                ), true)
            }
        } finally {
            photo.recycle()
        }
    }

    private fun requireAppFile(path: String) {
        val root = filesDir.parentFile!!.canonicalPath + "/"
        require(File(path).canonicalPath.startsWith(root))
    }

    private fun decodePhoto(path: String): Bitmap =
        if (Build.VERSION.SDK_INT >= 28) {
            android.graphics.ImageDecoder.decodeBitmap(
                android.graphics.ImageDecoder.createSource(File(path))
            ) { decoder, _, _ ->
                decoder.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } else {
            checkNotNull(BitmapFactory.decodeFile(path))
        }

    // Writes images, YOLO labels, data.yaml and a COCO JSON file into one ZIP in Downloads.
    private fun exportDataset(call: MethodCall): String {
        val classes = requireNotNull(call.argument<List<String>>("classes"))
        val items = requireNotNull(call.argument<List<Map<String, Any>>>("items"))
        val texts = requireNotNull(call.argument<Map<String, String>>("texts"))
        val fileName = requireNotNull(call.argument<String>("fileName"))
        require(Regex("^[A-Za-z0-9_.-]+\\.zip$").matches(fileName))
        items.forEach { requireAppFile(it["path"] as String) }

        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/zip")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/DeteksiObjek")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = checkNotNull(contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values))
            try {
                checkNotNull(contentResolver.openOutputStream(uri)).use { writeDataset(it, classes, items, texts) }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } catch (error: Exception) {
                contentResolver.delete(uri, null, null)
                throw error
            }
            return "Download/DeteksiObjek/$fileName"
        }
        val directory = checkNotNull(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS))
        val output = File(directory, fileName)
        val pending = File(directory, "$fileName.tmp")
        try {
            pending.outputStream().use { writeDataset(it, classes, items, texts) }
            check(pending.renameTo(output))
        } finally {
            pending.delete()
        }
        return output.absolutePath
    }

    private fun writeDataset(
        stream: OutputStream,
        classes: List<String>,
        items: List<Map<String, Any>>,
        texts: Map<String, String>,
    ) {
        val images = JSONArray()
        val annotations = JSONArray()
        var annotationId = 1
        ZipOutputStream(stream.buffered()).use { zip ->
            for ((name, text) in texts) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
            items.forEachIndexed { index, item ->
                val photo = decodePhoto(item["path"] as String)
                val width = photo.width
                val height = photo.height
                try {
                    // Re-encoding stores pixels upright, so boxes match without EXIF handling.
                    zip.putNextEntry(ZipEntry("images/${item["name"]}"))
                    check(photo.compress(Bitmap.CompressFormat.JPEG, 95, zip))
                    zip.closeEntry()
                } finally {
                    photo.recycle()
                }
                val imageId = index + 1
                images.put(JSONObject()
                    .put("id", imageId)
                    .put("file_name", item["name"])
                    .put("width", width)
                    .put("height", height))
                @Suppress("UNCHECKED_CAST")
                val boxes = item["boxes"] as List<List<Number>>
                val category = (item["classIndex"] as Number).toInt() + 1
                for (box in boxes) {
                    val left = box[0].toDouble() * width
                    val top = box[1].toDouble() * height
                    val boxWidth = (box[2].toDouble() - box[0].toDouble()) * width
                    val boxHeight = (box[3].toDouble() - box[1].toDouble()) * height
                    annotations.put(JSONObject()
                        .put("id", annotationId++)
                        .put("image_id", imageId)
                        .put("category_id", category)
                        .put("bbox", JSONArray(listOf(left, top, boxWidth, boxHeight)))
                        .put("area", boxWidth * boxHeight)
                        .put("iscrowd", 0))
                }
            }
            val categories = JSONArray()
            classes.forEachIndexed { index, name ->
                categories.put(JSONObject().put("id", index + 1).put("name", name))
            }
            zip.putNextEntry(ZipEntry("annotations_coco.json"))
            zip.write(JSONObject()
                .put("images", images)
                .put("annotations", annotations)
                .put("categories", categories)
                .toString().toByteArray(Charsets.UTF_8))
            zip.closeEntry()
        }
    }

    private fun appearance(bitmap: Bitmap, box: RectF, useEmbedding: Boolean): List<Double> {
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
        val basic = edges.map { it / edgeSum } + colors.map { it / colorSum }
        return if (useEmbedding) basic + imageEmbedding(bitmap, box) else basic
    }

    private fun addColorVote(histogram: DoubleArray, offset: Int, value: Double) {
        val position = value * 7
        val bin = position.toInt().coerceIn(0, 7)
        val fraction = position - bin
        histogram[offset + bin] += 1 - fraction
        histogram[offset + (bin + 1).coerceAtMost(7)] += fraction
    }

    private fun imageEmbedding(bitmap: Bitmap, box: RectF): List<Double> {
        if (embeddingUnavailable) return emptyList()
        val left = floor(box.left).toInt().coerceIn(0, bitmap.width - 1)
        val top = floor(box.top).toInt().coerceIn(0, bitmap.height - 1)
        val right = ceil(box.right).toInt().coerceIn(left + 1, bitmap.width)
        val bottom = ceil(box.bottom).toInt().coerceIn(top + 1, bitmap.height)
        if (right - left < 8 || bottom - top < 8) return emptyList()
        val model = embedder ?: try {
            ImageEmbedder.createFromOptions(
                applicationContext,
                ImageEmbedder.ImageEmbedderOptions.builder()
                    .setBaseOptions(BaseOptions.builder()
                        .setModelAssetPath("mobilenet_v3_small.tflite")
                        .build())
                    .setL2Normalize(true)
                    .setQuantize(false)
                    .build()
            ).also { embedder = it }
        } catch (_: Exception) {
            embeddingUnavailable = true
            return emptyList()
        } catch (_: LinkageError) {
            embeddingUnavailable = true
            return emptyList()
        }
        // createBitmap can return the source itself; copy it so closing the input cannot recycle it.
        val crop = Bitmap.createBitmap(bitmap, left, top, right - left, bottom - top).let {
            if (it === bitmap) it.copy(Bitmap.Config.ARGB_8888, false) else it
        }
        try {
            val input = BitmapImageBuilder(crop).build()
            try {
                return model.embed(input).embeddingResult().embeddings()
                    .firstOrNull()?.floatEmbedding()?.map { it.toDouble() } ?: emptyList()
            } finally {
                input.close()
            }
        } catch (_: Exception) {
            return emptyList()
        } finally {
            if (crop !== bitmap) crop.recycle()
        }
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        settingsChannel?.setMethodCallHandler(null)
        worker.execute {
            detector?.close()
            customDetector?.close()
            keptFrame?.recycle()
            embedder?.close()
        }
        worker.shutdown()
        exportWorker.shutdown()
        super.onDestroy()
    }
}
