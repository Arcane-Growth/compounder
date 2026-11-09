import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
// ---------------------------------------------------------------------------
// The upload keystore lives outside the repository; android/key.properties
// (gitignored) points at it. A release build must never silently fall back to
// the debug key: Play rejects an update signed with a different key, and a
// debug-signed artifact installs and runs fine locally, so the mistake would
// only surface at upload time. Instead, configuration fails with an actionable
// message before any release task runs.
//
// Escape hatch for a local `flutter run --release` on a machine without the
// keystore: set `compounder.allowDebugSigning=true` in
// ~/.gradle/gradle.properties. That file is user-level and never committed, so
// CI stays strict. See docs/release-build.md.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val allowDebugSigning =
    providers.gradleProperty("compounder.allowDebugSigning")
        .map { it.toBoolean() }
        .orElse(false)
        .get()

val missingSigningInputs = buildList {
    if (!keystorePropertiesFile.exists()) {
        add("android/key.properties does not exist")
    } else {
        keystoreProperties.load(keystorePropertiesFile.inputStream())
        val required = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        val blank = required.filter { keystoreProperties.getProperty(it).isNullOrBlank() }
        if (blank.isNotEmpty()) {
            add("android/key.properties is missing: ${blank.joinToString(", ")}")
        }
        val storeFile = keystoreProperties.getProperty("storeFile")
        if (!storeFile.isNullOrBlank() && !rootProject.file(storeFile).exists()) {
            add("keystore file not found at '$storeFile' (android/key.properties storeFile)")
        }
    }
}
val releaseSigningConfigured = missingSigningInputs.isEmpty()

android {
    namespace = "dev.compounder.compounder"
    // API 37 is a floor, not a pin: permission_handler_android 14.x compiles
    // against API 37 constants (ACCESS_LOCAL_NETWORK,
    // VERSION_CODES.CINNAMON_BUN), and AGP refuses to build an app whose
    // compileSdk is lower than a dependency's. Taking the max with Flutter's
    // default keeps this correct when Flutter moves past 36. targetSdk stays
    // on Flutter's default (36) and minSdk stays 26.
    compileSdk = maxOf(37, flutter.compileSdkVersion)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.compounder.compounder"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Only reached when releaseSigningConfigured, or when the local
            // escape hatch is set; the guard below fails the build otherwise.
            signingConfig =
                if (releaseSigningConfigured) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
            // R8: shrink, obfuscate and resource-shrink the release artifact.
            // Rules for plugins that resolve classes reflectively (Gson in
            // flutter_local_notifications, Tink in flutter_secure_storage) are
            // in proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// Fail loudly, at configuration time, when a release task is requested and the
// upload key is not available. `flutter build apk/appbundle --release` and
// `flutter run --release` request assembleRelease / bundleRelease, so the guard
// covers every path Flutter uses. (Gradle 9's Kotlin DSL no longer accepts a
// lambda for TaskExecutionGraph.whenReady, so the requested task names are the
// reliable signal here.)
val releaseRequested =
    gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
if (releaseRequested && !releaseSigningConfigured && !allowDebugSigning) {
    throw GradleException(
        buildString {
            appendLine("Release build is not signed with the upload key:")
            missingSigningInputs.forEach { appendLine("  - $it") }
            appendLine("Create android/key.properties (see docs/release-build.md), or set")
            appendLine("compounder.allowDebugSigning=true in ~/.gradle/gradle.properties for a")
            append("local `flutter run --release` without the keystore.")
        },
    )
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
