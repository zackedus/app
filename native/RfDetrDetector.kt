package id.rancangpro.object_detection

import android.content.Context
import android.graphics.Bitmap
import android.graphics.RectF
import org.json.JSONObject
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import kotlin.math.exp

/**
 * Runs an RF-DETR model exported with `model.export(format="tflite")`.
 *
 * Contract (from RF-DETR's export metadata): NHWC float32 RGB input, resized
 * without letterboxing and normalised with the stored mean/std; one output of
 * shape (1, Q, 4) with normalised cx, cy, w, h boxes and one of shape (1, Q, C)
 * with independent per-class logits (sigmoid, not softmax). Only class slots
 * named in the `.rfdetr.json` sidecar are reported, so unused or background
 * slots are ignored.
 */
class RfDetrDetector(context: Context, modelAsset: String, metadataAsset: String) : AutoCloseable {
    data class Detection(val box: RectF, val label: String, val score: Float)

    private val interpreter: Interpreter
    private val inputWidth: Int
    private val inputHeight: Int
    private val boxesIndex: Int
    private val logitsIndex: Int
    private val queries: Int
    private val classSlots: Int
    private val means: FloatArray
    private val stds: FloatArray
    private val names: Map<Int, String>
    private val input: ByteBuffer
    private val boxesOutput: ByteBuffer
    private val logitsOutput: ByteBuffer
    private val pixels: IntArray

    val classNames: List<String> get() = names.toSortedMap().values.toList()

    init {
        val model = context.assets.openFd(modelAsset).use { descriptor ->
            FileInputStream(descriptor.fileDescriptor).channel.use { channel ->
                channel.map(FileChannel.MapMode.READ_ONLY, descriptor.startOffset, descriptor.declaredLength)
            }
        }
        interpreter = Interpreter(model, Interpreter.Options().setNumThreads(4))
        val inputTensor = interpreter.getInputTensor(0)
        val shape = inputTensor.shape()
        require(shape.size == 4 && shape[0] == 1 && shape[3] == 3) {
            "Model RF-DETR harus berinput NHWC (1, H, W, 3), bukan ${shape.contentToString()}"
        }
        require(inputTensor.dataType() == DataType.FLOAT32) { "Input model harus float32" }
        inputHeight = shape[1]
        inputWidth = shape[2]

        val root = JSONObject(context.assets.open(metadataAsset).bufferedReader().use { it.readText() })
        val metadata = root.optJSONObject("metadata") ?: root

        val rank3 = (0 until interpreter.outputTensorCount)
            .filter { interpreter.getOutputTensor(it).shape().size == 3 }
        require(rank3.size == 2) { "Model RF-DETR deteksi harus punya 2 output rank-3" }
        val withFour = rank3.filter { interpreter.getOutputTensor(it).shape()[2] == 4 }
        val (boxes, logits) = when (withFour.size) {
            1 -> withFour[0] to rank3.first { it != withFour[0] }
            else -> {
                // Four classes make both outputs end in 4; use the exported output positions.
                val outputs = metadata.optJSONObject("outputs")
                val dets = outputs?.opt("dets") as? Int
                val labels = outputs?.opt("labels") as? Int
                require(dets != null && labels != null) { "Output kotak/logit RF-DETR ambigu" }
                dets to labels
            }
        }
        boxesIndex = boxes
        logitsIndex = logits
        queries = interpreter.getOutputTensor(boxes).shape()[1]
        classSlots = interpreter.getOutputTensor(logits).shape()[2]
        require(interpreter.getOutputTensor(logits).shape()[1] == queries)

        means = floats(metadata, "means", floatArrayOf(0.485f, 0.456f, 0.406f))
        stds = floats(metadata, "stds", floatArrayOf(0.229f, 0.224f, 0.225f))
        names = classNamesFrom(metadata, classSlots)
        require(names.isNotEmpty()) { "Nama kelas tidak ada di metadata RF-DETR" }

        input = ByteBuffer.allocateDirect(4 * inputWidth * inputHeight * 3).order(ByteOrder.nativeOrder())
        boxesOutput = ByteBuffer.allocateDirect(4 * queries * 4).order(ByteOrder.nativeOrder())
        logitsOutput = ByteBuffer.allocateDirect(4 * queries * classSlots).order(ByteOrder.nativeOrder())
        pixels = IntArray(inputWidth * inputHeight)
    }

    fun detect(bitmap: Bitmap, threshold: Float, maxResults: Int): List<Detection> {
        val resized = Bitmap.createScaledBitmap(bitmap, inputWidth, inputHeight, true)
        try {
            resized.getPixels(pixels, 0, inputWidth, 0, 0, inputWidth, inputHeight)
        } finally {
            if (resized !== bitmap) resized.recycle()
        }
        input.rewind()
        for (pixel in pixels) {
            input.putFloat((((pixel shr 16) and 0xff) / 255f - means[0]) / stds[0])
            input.putFloat((((pixel shr 8) and 0xff) / 255f - means[1]) / stds[1])
            input.putFloat(((pixel and 0xff) / 255f - means[2]) / stds[2])
        }
        input.rewind()
        boxesOutput.rewind()
        logitsOutput.rewind()
        interpreter.runForMultipleInputsOutputs(
            arrayOf<Any>(input),
            mapOf<Int, Any>(boxesIndex to boxesOutput, logitsIndex to logitsOutput),
        )
        boxesOutput.rewind()
        logitsOutput.rewind()
        val boxes = boxesOutput.asFloatBuffer()
        val logits = logitsOutput.asFloatBuffer()

        val found = ArrayList<Detection>()
        for (query in 0 until queries) {
            var bestSlot = -1
            var bestLogit = Float.NEGATIVE_INFINITY
            for ((slot, _) in names) {
                val logit = logits.get(query * classSlots + slot)
                if (logit > bestLogit) {
                    bestLogit = logit
                    bestSlot = slot
                }
            }
            val score = 1f / (1f + exp(-bestLogit))
            if (bestSlot < 0 || score < threshold) continue
            val cx = boxes.get(query * 4)
            val cy = boxes.get(query * 4 + 1)
            val w = boxes.get(query * 4 + 2)
            val h = boxes.get(query * 4 + 3)
            val box = RectF(
                ((cx - w / 2) * bitmap.width).coerceIn(0f, bitmap.width.toFloat()),
                ((cy - h / 2) * bitmap.height).coerceIn(0f, bitmap.height.toFloat()),
                ((cx + w / 2) * bitmap.width).coerceIn(0f, bitmap.width.toFloat()),
                ((cy + h / 2) * bitmap.height).coerceIn(0f, bitmap.height.toFloat()),
            )
            if (box.width() < 1f || box.height() < 1f) continue
            found.add(Detection(box, names.getValue(bestSlot), score))
        }
        return found.sortedByDescending { it.score }.take(maxResults)
    }

    override fun close() = interpreter.close()

    private companion object {
        fun floats(metadata: JSONObject, key: String, fallback: FloatArray): FloatArray {
            val values = metadata.optJSONArray(key) ?: return fallback
            if (values.length() != 3) return fallback
            return FloatArray(3) { values.getDouble(it).toFloat() }
        }

        fun classNamesFrom(metadata: JSONObject, slots: Int): Map<Int, String> {
            val mapping = metadata.optJSONObject("class_id_to_name")
            val result = sortedMapOf<Int, String>()
            if (mapping != null && mapping.length() > 0) {
                for (key in mapping.keys()) {
                    val slot = key.toIntOrNull() ?: continue
                    if (slot in 0 until slots) result[slot] = mapping.getString(key)
                }
                return result
            }
            // Zero-indexed names; a trailing extra slot is the background.
            val list = metadata.optJSONArray("class_names") ?: return result
            for (index in 0 until minOf(list.length(), slots)) result[index] = list.getString(index)
            return result
        }
    }
}
