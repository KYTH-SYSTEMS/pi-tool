import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is configured via android/key.properties (created locally or
// by CI from secrets). When the file is absent we fall back to debug signing so
// `flutter run --release` keeps working without a keystore.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystore = keystorePropertiesFile.exists()
if (hasKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "systems.kyth.pitool"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Published application identity under KYTH. Systems UG. Changed once,
        // before any Play release, from the legacy de.grasse.evcc_updater — a new
        // id orphans existing installs (reinstall needed) and is permanent once
        // on Play, so it must not change again after publication.
        applicationId = "systems.kyth.pitool"
        minSdk = flutter.minSdkVersion
        // Pinned explicitly: Play requires new apps/updates to target the
        // current API level — raised to 36 (Android 16) on 2026-07-27, when the
        // console started blocking further updates on API 35.
        // What targeting 36 changes for us (all checked, nothing to do):
        //  * Edge-to-edge is mandatory, the opt-out attribute is gone — our
        //    layouts already respect the insets (Scaffold/AppBar/NavigationBar,
        //    SafeArea in the full-screen routes), verified by rendering with
        //    simulated system bars.
        //  * Predictive back is on by default; Flutter's embedding handles the
        //    OnBackInvokedCallback, and the one PopScope we use (the scan
        //    dialog) blocks dismissal deliberately.
        //  * Orientation/resizability restrictions are ignored on large screens
        //    — we never set screenOrientation or resizeableActivity.
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasKeystore) {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            // Use the real release keystore when available (CI / signed builds),
            // otherwise fall back to debug signing for local convenience.
            signingConfig = if (hasKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 pinned explicitly. The Flutter Gradle Plugin already turns it
            // on for release builds (v0.67.0 shipped with ~96 % of its classes
            // renamed), but Play's technical quality requirements demand at
            // least 25 % shrinking/optimization/obfuscation from February 2027
            // — too important to leave to a plugin default that a Flutter
            // upgrade could quietly change. Our DEX is ~2.7 MB and the rule
            // only bites above 10 MB, so this is a guard rail, not a fix.
            // isShrinkResources stays off on purpose: it buys a little size at
            // the price of resources that are only referenced by name at
            // runtime, and nothing requires it.
            isMinifyEnabled = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
