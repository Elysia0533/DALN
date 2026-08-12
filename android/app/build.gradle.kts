import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("org.jetbrains.kotlin.plugin.serialization")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningTasks = gradle.startParameter.taskNames.any {
    val taskName = it.lowercase()
    taskName.contains("release")
}
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(propertyName: String, environmentName: String): String {
    return (keystoreProperties.getProperty(propertyName) ?: System.getenv(environmentName)).orEmpty()
}

val releaseStoreFile = signingValue("storeFile", "VBOOK_RELEASE_STORE_FILE")
val releaseStorePassword = signingValue("storePassword", "VBOOK_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "VBOOK_RELEASE_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "VBOOK_RELEASE_KEY_PASSWORD")

fun releaseStoreFilePath(): File {
    val configuredFile = File(releaseStoreFile)
    return if (configuredFile.isAbsolute) configuredFile else rootProject.file(releaseStoreFile)
}

if (releaseSigningTasks) {
    val missing = buildList {
        if (releaseStoreFile.isBlank()) add("storeFile / VBOOK_RELEASE_STORE_FILE")
        if (releaseStorePassword.isBlank()) add("storePassword / VBOOK_RELEASE_STORE_PASSWORD")
        if (releaseKeyAlias.isBlank()) add("keyAlias / VBOOK_RELEASE_KEY_ALIAS")
        if (releaseKeyPassword.isBlank()) add("keyPassword / VBOOK_RELEASE_KEY_PASSWORD")
    }
    if (missing.isNotEmpty()) {
        throw GradleException(
            "Release signing is not configured. Missing: ${missing.joinToString(", ")}. " +
                "Create android/key.properties locally or set the VBOOK_RELEASE_* environment variables."
        )
    }
    if (!releaseStoreFilePath().exists()) {
        throw GradleException(
            "Release signing keystore was not found at '${releaseStoreFilePath()}'. " +
                "Update storeFile in android/key.properties or VBOOK_RELEASE_STORE_FILE."
        )
    }
}

android {
    namespace = "com.vbook.reader"
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
        applicationId = "com.vbook.reader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseStoreFile.isNotBlank()) {
                storeFile = releaseStoreFilePath()
            }
            if (releaseStorePassword.isNotBlank()) {
                storePassword = releaseStorePassword
            }
            if (releaseKeyAlias.isNotBlank()) {
                keyAlias = releaseKeyAlias
            }
            if (releaseKeyPassword.isNotBlank()) {
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("app.cash.quickjs:quickjs-android:0.9.2")
    implementation("org.jsoup:jsoup:1.17.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.logcat:logcat:0.1")
}
