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
source += '\ndependencies {\n    implementation("org.tensorflow:tensorflow-lite-task-vision:0.4.4")\n}\n'
gradle.write_text(source)
PY

cd "$project"
flutter pub get
