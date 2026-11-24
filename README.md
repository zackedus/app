# Deteksi Objek

Prototipe Flutter untuk Android. Kamera belakang menampilkan kotak, nama objek, dan skor model secara langsung. Model EfficientDet-Lite0 (COCO) disertakan, sehingga aplikasi dapat mendeteksi objek umum seperti orang, botol, kursi, dan kendaraan secara offline. Angka di bawah kamera adalah jumlah deteksi saat ini. Skor pada kotak adalah keyakinan model untuk deteksi itu.

## Menjalankan

Gunakan komputer dengan Flutter 3.35 atau lebih baru, Android SDK, Java, Python 3, dan Bash. Sambungkan HP Android dengan USB debugging aktif. Koneksi internet diperlukan saat mengambil dependensi build.

```sh
bash setup.sh
cd object_detection
flutter run
```

Untuk membuat APK pengujian, jalankan `flutter build apk --debug` di folder `object_detection`. Hasilnya berada di `build/app/outputs/flutter-apk/app-debug.apk`.

## Uji di HP

- Izinkan akses kamera, lalu arahkan kamera ke orang, botol, dan kursi. Periksa apakah kotak mengikuti posisi objek.
- Pindahkan kamera ke area kosong. Kotak lama akan hilang setelah frame baru diproses.
- Pindah ke aplikasi lain lalu kembali. Kamera dan deteksi seharusnya aktif kembali.
- Aktifkan mode pesawat dan ulangi deteksi.

## Fitur lapangan

- **Simpan foto**: menyimpan frame kamera beserta kotak, label, waktu, lokasi GPS terakhir (bisa dimatikan), ringkasan objek, dan nama model ke `Pictures/DeteksiObjek/`. Ada tombol **Bagikan** setelah tersimpan.
- **Hitung objek**: pelacakan antar-frame (IoU); objek dihitung sekali setelah terlihat 3 frame. Panel menampilkan jumlah yang terlihat dan total, plus tombol reset.
- **Deteksi dari foto** (menu ⋮): pilih foto dari HP, lihat hasil deteksi, simpan hasilnya, atau jadikan contoh dataset dengan kotak deteksi sebagai anotasi awal.
- **Pengaturan deteksi** (menu ⋮): ambang keyakinan, batas frame per detik (hemat baterai), lokasi di foto, dan pilihan kelas yang ditampilkan.

## Objek kustom dan dataset

- Tombol **Tambahkan objek baru** memotret contoh. Jika API key OpenRouter diisi, foto bisa dianotasi otomatis (default `google/gemini-3.8-flash`, format kotak bawaan Gemini `box_2d` 0–1000; Qwen `bbox_2d` juga dibaca), lalu dikoreksi manual.
- Kelas kustom aktif setelah minimal 3 foto beranotasi. Vektor fitur disimpan di samping foto (`.vec.json`) sehingga hanya foto baru atau yang diubah yang diproses ulang.
- **Galeri dataset**: hapus foto atau kelas, dan ekspor ZIP berisi `images/`, `labels/` (YOLO), `data.yaml`, dan `annotations_coco.json` (COCO). File tersimpan di `Download/DeteksiObjek/` (Android 10+) untuk fine-tuning RF-DETR/YOLO.

## Detektor sendiri (RF-DETR)

Lihat `training/README.md`: ekspor dataset dari aplikasi, latih RF-DETR Nano di Colab (`training/train_rfdetr.ipynb`), lalu taruh `custom_model.tflite` dan `custom_model.tflite.rfdetr.json` di `native/`. Jika file itu ada, aplikasi memakainya sebagai pengganti EfficientDet.

Kamera memakai implementasi CameraX (`camera_android_camerax`).

## Google Play 16 KB

Detektor memakai MediaPipe Tasks (`tasks-vision` 0.10.33) yang library native-nya mendukung halaman 16 KB. Workflow CI menjalankan `scripts/check_16kb.py` pada APK dan gagal jika ada `.so` arm64 yang belum selaras 16 KB.

Model berasal dari [contoh TensorFlow Lite Object Detection](https://github.com/tensorflow/examples/tree/master/lite/examples/object_detection/android), dengan [berkas model dari Google](https://storage.googleapis.com/download.tensorflow.org/models/tflite/task_library/object_detection/android/lite-model_efficientdet_lite0_detection_metadata_1.tflite).

## GitHub Actions

Letakkan isi paket ini di root repositori, termasuk folder tersembunyi `.github`.
Workflow **Android test and APK** menjalankan analisis Dart dan widget test, lalu
membuat APK debug ARM64. Jika berhasil, APK tersedia sebagai artefak
`deteksi-objek-android-arm64` pada halaman run di tab **Actions**.
Widget test menguji pesan saat kamera tidak tersedia dan izin kamera ditolak,
serta tombol coba lagi. Validasi kotak deteksi dan mode offline memakai HP fisik.
