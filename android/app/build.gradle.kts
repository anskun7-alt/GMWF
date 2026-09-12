import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val rootKeyProps = rootProject.file("key.properties")
val appKeyProps = file("key.properties")
val keystorePropertiesFile = if (rootKeyProps.exists()) rootKeyProps else appKeyProps
val appKeystoreFile = file("gmwf-release.jks")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.gm_new"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
        languageVersion = "1.8"
        apiVersion = "1.8"
    }

    defaultConfig {
        applicationId = "com.example.gm_new"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists() && keystoreProperties.getProperty("storeFile") != null) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                val storeFilePath = keystoreProperties.getProperty("storeFile")
                storeFile = if (file(storeFilePath).exists()) file(storeFilePath) else file("gmwf-release.jks")
                storePassword = keystoreProperties.getProperty("storePassword")
            } else if (appKeystoreFile.exists()) {
                keyAlias = "gmwfkey"
                keyPassword = "gmwfappkeypassword123"
                storeFile = appKeystoreFile
                storePassword = "gmwfappkeypassword123"
            } else {
                keyAlias = "androiddebugkey"
                keyPassword = "android"
                storeFile = file("${System.getProperty("user.home")}/.android/debug.keystore")
                storePassword = "android"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

