import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase's native initializer also needs public project identifiers so a
// notification can be delivered after process death. Read the same build-time
// config as Flutter; never include a server credential or device token here.
val relayPushDefines = (project.findProperty("dart-defines") as? String)
    ?.split(",")?.mapNotNull { encoded ->
        val decoded = runCatching { String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) }.getOrNull()
        val parts = decoded?.split("=", limit = 2)
        if (parts?.size == 2 && parts[0].startsWith("RELAY_")) parts[0] to parts[1] else null
    }?.toMap() ?: emptyMap()

android {
    namespace = "com.example.ryza_chat_mvp"
    compileSdk = 37
    // Use the highest NDK required by the native Flutter plugins.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.ryza_chat_mvp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        multiDexEnabled = true
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (relayPushDefines["RELAY_PUSH_PROVIDER"] == "fcm") {
            mapOf(
                "google_api_key" to "RELAY_FCM_API_KEY",
                "google_app_id" to "RELAY_FCM_APP_ID",
                "gcm_defaultSenderId" to "RELAY_FCM_SENDER_ID",
                "project_id" to "RELAY_FCM_PROJECT_ID",
            ).forEach { (resource, field) ->
                val value = relayPushDefines[field]
                require(!value.isNullOrBlank()) { "Missing public FCM configuration: $field" }
                resValue("string", resource, value)
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs.useLegacyPackaging = true
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

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
}
