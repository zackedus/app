#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
project=object_detection
if [[ -e "$project" ]]; then
  echo "Folder $project sudah ada. Pindahkan folder itu sebelum menjalankan ulang." >&2
  exit 1
fi

flutter create --no-pub --platforms=android --org id.rancangpro "$project"
cp pubspec.yaml "$project/pubspec.yaml"
cp lib/main.dart "$project/lib/main.dart"
rm "$project/test/widget_test.dart"
cp test/detection_screen_test.dart "$project/test/detection_screen_test.dart"
rm "$project/analysis_options.yaml"
app="$project/android/app"
mkdir -p "$app/src/main/assets"
cp native/model.tflite "$app/src/main/assets/model.tflite"
cp native/MainActivity.kt "$app/src/main/kotlin/id/rancangpro/object_detection/MainActivity.kt"

python3 - "$app" <<'PY'
from pathlib import Path
import os
import sys

app = Path(sys.argv[1])
manifest = app / "src/main/AndroidManifest.xml"
xml = manifest.read_text()
xml = xml.replace(
    "    <application",
    '    <uses-permission android:name="android.permission.INTERNET" />\n'
    '    <uses-permission android:name="android.permission.CAMERA" />\n'
    '    <uses-feature android:name="android.hardware.camera" android:required="true" />\n'
    '    <application',
    1,
)
xml = xml.replace('android:label="object_detection"', 'android:label="Deteksi Objek"')
xml = xml.replace('android:name=".MainActivity"', 'android:name=".MainActivity"\n            android:screenOrientation="portrait"')
manifest.write_text(xml)

gradle = app / "build.gradle.kts"
source = gradle.read_text()
assert "android {" in source and "minSdk = flutter.minSdkVersion" in source
source = source.replace("android {", 'android {\n    androidResources {\n        noCompress += "tflite"\n    }\n', 1)
source = source.replace("minSdk = flutter.minSdkVersion", "minSdk = maxOf(flutter.minSdkVersion, 24)", 1)
source += '\ndependencies {\n    implementation("org.tensorflow:tensorflow-lite-task-vision:0.4.4")\n    implementation("com.google.auto.value:auto-value-annotations:1.11.0")\n}\n'
if os.environ.get("ANDROID_RELEASE") == "1":
    base_id = 'applicationId = "id.rancangpro.object_detection"'
    debug_signing = 'signingConfig = signingConfigs.getByName("debug")'
    if base_id not in source or debug_signing not in source:
        raise RuntimeError("Template Android berubah. Periksa konfigurasi rilis.")
    source = source.replace(base_id, 'applicationId = "id.rancangpro.object_detection.release"')
    source = source.replace('android {', """android {
    signingConfigs {
        create("persistentRelease") {
            storeFile = file(System.getenv("ANDROID_KEYSTORE_PATH"))
            storeType = "PKCS12"
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
        }
    }
""", 1)
    source = source.replace(debug_signing, 'signingConfig = signingConfigs.getByName("persistentRelease")')
    manifest.write_text(xml.replace('android:label="Deteksi Objek"', 'android:label="Deteksi Objek Rilis"'))
gradle.write_text(source)
PY

cd "$project"
flutter pub get
