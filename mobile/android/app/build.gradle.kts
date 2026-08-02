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
    }

    buildTypes {
        release {
            // Release artifacts are intentionally unsigned until an operator
            // supplies a reviewed signing configuration. Never ship debug keys.
            signingConfig = null
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
