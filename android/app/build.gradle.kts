import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load android/key.properties if it exists. This file is .gitignore'd and
// holds the release keystore passwords + alias. When it is missing (e.g.
// fresh checkout, CI without secrets, or anyone who hasn't run
// scripts/generate_release_keystore.sh yet), we fall back to the debug
// signing config so `flutter run --release` still works.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
val hasReleaseSigning = keystorePropertiesFile.exists() &&
    keystoreProperties.getProperty("storeFile") != null &&
    keystoreProperties.getProperty("storePassword") != null &&
    keystoreProperties.getProperty("keyAlias") != null &&
    keystoreProperties.getProperty("keyPassword") != null

android {
    namespace = "com.johnsondigital.loadout"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.johnsondigital.loadout"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                // storeFile is resolved relative to this module (android/app).
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // If android/key.properties is present we sign with the real
            // release keystore. Otherwise fall back to the debug keystore so
            // local `flutter run --release` keeps working without secrets.
            // The debug fallback MUST NOT ship to the Play Store — see
            // CLAUDE.md "Android gotchas".
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Google Play Services Wearable Data Layer — used by WatchBridge.kt to
    // mirror the iOS WatchSessionBridge: DataItems for lossy DOPE / active-
    // load payloads and Messages for the live timer / shot-log channel.
    // Required by every reference under `com.google.android.gms.wearable.*`
    // and `com.google.android.gms.tasks.Tasks` in the phone module.
    // See CLAUDE.md §15 for the watch / Wear OS architecture overview.
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
}
