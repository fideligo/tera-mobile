plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "id.tera.tera_patient"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications, which uses java.time on minSdk 26.
        //
        // Without it the build fails at `:app:checkDebugAarMetadata` with "Dependency
        // ':flutter_local_notifications' requires core library desugaring to be enabled" — a hard
        // failure, not a warning, so the app will not start at all. Adding the plugin without this
        // is what broke `flutter run`.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "id.tera.tera_patient"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // R8 runs on release builds and failed the moment ML Kit arrived: its plugin names
            // script variants the app does not depend on. proguard-rules.pro says why they are
            // safe to leave out rather than pulling in several megabytes of unused models.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // The desugaring runtime itself. flutter_local_notifications 18 requires 2.1.4 or newer; an
    // older one fails the same metadata check with a version message instead of an absence one.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

