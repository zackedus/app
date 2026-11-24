package id.rancangpro.object_detection

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Drawing, saving and loading of photos for snapshots and gallery detection. */
object PhotoTools {
    private const val ACCENT = 0xff79ebbb.toInt()

    /**
     * Returns a copy of [source] with boxes (normalised l, t, r, b), their
     * labels and a caption bar drawn at the same scale for any resolution.
     */
    fun annotate(source: Bitmap, boxes: List<List<Number>>, labels: List<String>, caption: String): Bitmap {
        val width = source.width
        val height = source.height
        val unit = max(width, height) / 320f
        val captionLines = caption.lines().filter { it.isNotBlank() }
        val textSize = 9f * unit
        val lineHeight = textSize * 1.35f
        val footer = if (captionLines.isEmpty()) 0 else (lineHeight * captionLines.size + 6f * unit).roundToInt()

        val result = Bitmap.createBitmap(width, height + footer, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result)
        canvas.drawColor(Color.BLACK)
        canvas.drawBitmap(source, 0f, 0f, null)

        val border = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ACCENT
            style = Paint.Style.STROKE
            strokeWidth = 1.5f * unit
        }
        val tag = Paint().apply { color = ACCENT }
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK
            this.textSize = textSize
        }
        for ((index, box) in boxes.withIndex()) {
            if (box.size != 4) continue
            val rect = RectF(
                box[0].toFloat() * width, box[1].toFloat() * height,
                box[2].toFloat() * width, box[3].toFloat() * height,
            )
            canvas.drawRect(rect, border)
            val label = labels.getOrNull(index).orEmpty()
            if (label.isEmpty()) continue
            val tagWidth = min(text.measureText(label) + 6f * unit, width.toFloat())
            val tagHeight = lineHeight + 2f * unit
            val left = rect.left.coerceIn(0f, max(0f, width - tagWidth))
            val top = (rect.top - tagHeight).coerceIn(0f, max(0f, height - tagHeight))
            canvas.drawRect(left, top, left + tagWidth, top + tagHeight, tag)
            canvas.drawText(label, left + 3f * unit, top + tagHeight - 4f * unit, text)
        }

        if (footer > 0) {
            val footerText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                this.textSize = textSize
            }
            var baseline = height + 3f * unit + textSize
            for (line in captionLines) {
                canvas.drawText(line, 4f * unit, baseline, footerText)
                baseline += lineHeight
            }
        }
        return result
    }

    /** Saves a JPEG to Pictures/DeteksiObjek. Returns a readable location and a shareable URI. */
    fun saveJpeg(context: Context, bitmap: Bitmap, fileName: String): Pair<String, Uri?> {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/DeteksiObjek")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
            try {
                checkNotNull(resolver.openOutputStream(uri)).use {
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it))
                }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            return "Pictures/DeteksiObjek/$fileName" to uri
        }
        val directory = checkNotNull(context.getExternalFilesDir(Environment.DIRECTORY_PICTURES))
        val output = File(directory, fileName)
        output.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it)) }
        return output.absolutePath to null
    }

    /**
     * Decodes a picked image upright (EXIF applied on Android 9+), limits the
     * longer side to [maxSide] and stores it as JPEG in the app cache.
     */
    fun importPicked(context: Context, uri: Uri, maxSide: Int = 2048): Triple<String, Int, Int> {
        val decoded = if (Build.VERSION.SDK_INT >= 28) {
            android.graphics.ImageDecoder.decodeBitmap(
                android.graphics.ImageDecoder.createSource(context.contentResolver, uri)
            ) { decoder, info, _ ->
                decoder.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
                val longest = max(info.size.width, info.size.height)
                if (longest > maxSide) {
                    val scale = maxSide.toFloat() / longest
                    decoder.setTargetSize(
                        (info.size.width * scale).roundToInt().coerceAtLeast(1),
                        (info.size.height * scale).roundToInt().coerceAtLeast(1),
                    )
                }
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / sample > maxSide) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            checkNotNull(context.contentResolver.openInputStream(uri).use {
                BitmapFactory.decodeStream(it, null, options)
            })
        }
        try {
            val directory = File(context.cacheDir, "picked").apply { mkdirs() }
            directory.listFiles()?.forEach { it.delete() }
            val output = File(directory, "foto_${System.currentTimeMillis()}.jpg")
            output.outputStream().use { check(decoded.compress(Bitmap.CompressFormat.JPEG, 95, it)) }
            return Triple(output.absolutePath, decoded.width, decoded.height)
        } finally {
            decoded.recycle()
        }
    }
}
