import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key (docs/ci.md, "Signing"). CI passes it through the
// ANDROID_KEYSTORE_FILE / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS /
// ANDROID_KEY_PASSWORD environment variables; local builds read
// android/key.properties (gitignored: storeFile, storePassword, keyAlias,
// keyPassword). Without either, release builds fall back to the debug key.
val releaseSigning: Map<String, String>? = run {
    val env = System.getenv()
    val envFile = env["ANDROID_KEYSTORE_FILE"]
    if (!envFile.isNullOrEmpty()) {
        mapOf(
            "storeFile" to envFile,
            "storePassword" to env.getValue("ANDROID_KEYSTORE_PASSWORD"),
            "keyAlias" to env.getValue("ANDROID_KEY_ALIAS"),
            "keyPassword" to env.getValue("ANDROID_KEY_PASSWORD"),
        )
    } else {
        val file = rootProject.file("key.properties")
        if (file.exists()) {
            val props = Properties().apply { file.inputStream().use { load(it) } }
            listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
                .associateWith { props.getProperty(it) ?: error("key.properties lacks $it") }
        } else {
            null
        }
    }
}

android {
    namespace = "net.ivanik.sdr_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "net.ivanik.sdr_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Native AAudio is the sole audio backend; it requires Android API 26.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Build our new core only for arm64; keep other debug ABIs for Flutter/emulators.
        externalNativeBuild {
            cmake {
                abiFilters.add("arm64-v8a")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (releaseSigning != null) {
            create("release") {
                storeFile = file(releaseSigning.getValue("storeFile"))
                storePassword = releaseSigning.getValue("storePassword")
                keyAlias = releaseSigning.getValue("keyAlias")
                keyPassword = releaseSigning.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseSigning != null) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("No release signing key; signing the release build with the debug key.")
                signingConfigs.getByName("debug")
            }
        }
    }
}

// Release target is arm64-v8a only: libsdrcore is built for arm64-v8a.
// Debug keeps Flutter's emulator ABIs; missing native ABI is reported in the UI.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            listOf("lib/armeabi-v7a/**", "lib/armeabi/**", "lib/x86/**", "lib/x86_64/**"),
        )
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
    testImplementation("junit:junit:4.13.2")
}
