plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun quotedBuildValue(name: String): String {
    val value = providers.gradleProperty(name).orElse("").get()
    require(!value.contains('"') && !value.contains('\\')) { "$name contains invalid characters" }
    return "\"$value\""
}

// Flutter passes every --dart-define to Gradle as "dart-defines": base64
// "NAME=value" entries joined by commas. Native phone notices (D52) exist only
// in a demo build that also asks for them; this is decided here at build time,
// never from a value Dart sends at runtime, and never in a release build type.
fun dartDefine(name: String): String? {
    val raw = providers.gradleProperty("dart-defines").orNull ?: return null
    return raw.split(',').mapNotNull {
        runCatching { String(java.util.Base64.getDecoder().decode(it), Charsets.UTF_8) }.getOrNull()
    }.lastOrNull { it.startsWith("$name=") }?.substringAfter('=')
}
val phoneNoticesBuild = dartDefine("VERITRA_DEMO") == "true" && dartDefine("VERITRA_PHONE_NOTICES") == "true"

android {
    namespace = "org.veritra.private_messenger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { buildConfig = true }

    defaultConfig {
        applicationId = "org.veritra.private_messenger"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "VERITRA_FCM_APPLICATION_ID", quotedBuildValue("VERITRA_FCM_APPLICATION_ID"))
        buildConfigField("String", "VERITRA_FCM_API_KEY", quotedBuildValue("VERITRA_FCM_API_KEY"))
        buildConfigField("String", "VERITRA_FCM_PROJECT_ID", quotedBuildValue("VERITRA_FCM_PROJECT_ID"))
        buildConfigField("String", "VERITRA_FCM_SENDER_ID", quotedBuildValue("VERITRA_FCM_SENDER_ID"))
        buildConfigField("boolean", "VERITRA_PHONE_NOTICES", phoneNoticesBuild.toString())
    }

    buildTypes {
        release {
            // Release artifacts are intentionally unsigned until an operator
            // supplies a reviewed signing configuration. Never ship debug keys.
            signingConfig = null
            // Release builds never carry phone notices, whatever the defines.
            buildConfigField("boolean", "VERITRA_PHONE_NOTICES", "false")
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

dependencies {
    implementation("org.unifiedpush.android:connector:3.3.3")
    implementation("com.google.firebase:firebase-messaging:25.0.1")
}

configurations.configureEach {
    val tink = "com.google.crypto.tink:tink-android:1.21.0"
    resolutionStrategy {
        force(tink)
        dependencySubstitution {
            substitute(module("com.google.crypto.tink:tink")).using(module(tink))
        }
    }
}
