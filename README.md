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

Model berasal dari [contoh TensorFlow Lite Object Detection](https://github.com/tensorflow/examples/tree/master/lite/examples/object_detection/android), dengan [berkas model dari Google](https://storage.googleapis.com/download.tensorflow.org/models/tflite/task_library/object_detection/android/lite-model_efficientdet_lite0_detection_metadata_1.tflite).

## GitHub Actions

Letakkan isi paket ini di root repositori, termasuk folder tersembunyi `.github`.
Workflow **Android test and APK** menjalankan analisis Dart dan widget test, lalu
membuat APK debug ARM64. Jika berhasil, APK tersedia sebagai artefak
`deteksi-objek-android-arm64` pada halaman run di tab **Actions**.
Widget test menguji pesan saat kamera tidak tersedia dan izin kamera ditolak,
serta tombol coba lagi. Validasi kotak deteksi dan mode offline memakai HP fisik.
