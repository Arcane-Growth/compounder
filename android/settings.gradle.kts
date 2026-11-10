pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.5.1" apply false
    // No legacy Kotlin Gradle Plugin (KGP) declaration here: AGP 9 provides
    // Kotlin support natively (android.builtInKotlin=true). Flutter is
    // removing KGP support.
}

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        // AGP 9's built-in Kotlin support pins KGP 2.2.10, which is below
        // Flutter's minimum supported version (2.2.20). Adding a newer KGP to
        // the buildscript classpath upgrades it without applying the plugin,
        // so built-in Kotlin stays in charge of compilation.
        // https://developer.android.com/build/releases/agp-9-0-0-release-notes#built-in-kotlin
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.21")
    }
}

include(":app")
