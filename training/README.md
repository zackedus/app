# Fine-tune detektor sendiri (RF-DETR Nano)

RF-DETR Nano berlisensi Apache 2.0, jadi aman dipakai di aplikasi komersial yang kodenya tertutup.

1. **Kumpulkan data di aplikasi.** Ambil foto contoh, anotasi (otomatis lewat AI lalu koreksi manual), lalu buka Galeri dataset → tombol ekspor. ZIP tersimpan di `Download/DeteksiObjek/`.
2. **Latih di Colab.** Buka `train_rfdetr.ipynb` di Google Colab dengan runtime GPU. Notebook ini:
   - memecah ZIP menjadi train/valid/test (`prepare_dataset.py`),
   - melatih RF-DETR Nano,
   - mengekspor ke TFLite, lalu mengunduh `custom_model.tflite` dan `custom_model.tflite.rfdetr.json`.
3. **Pasang ke aplikasi.** Taruh kedua file di folder `native/`, lalu jalankan `bash setup.sh` (atau push supaya GitHub Actions membuat APK). Baris status di aplikasi akan menampilkan **Model: RF-DETR kustom**. Kalau model gagal dimuat, aplikasi kembali ke EfficientDet dan menampilkan alasannya di baris status.

## Catatan

- File model bisa berukuran puluhan MB. Jangan commit ke repo publik kalau datanya rahasia.
- Kalau model FP16 bermasalah di HP tertentu, pakai `inference_model_fp32.tflite` beserta file `.rfdetr.json`-nya, dengan nama yang sama seperti di atas.
- Ambang skor di aplikasi 0,35. Kotak dipetakan langsung karena RF-DETR memakai resize tanpa letterbox.
- Uji ukuran data: `python prepare_dataset.py dataset.zip keluaran`. Script butuh minimal 3 foto beranotasi, tapi untuk hasil yang andal mulailah dari ratusan foto per kelas.
