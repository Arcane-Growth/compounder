# R8 rules for Compounder's release build.
#
# AGP 9 runs R8 in full mode: on top of proguard-android-optimize.txt there are
# no implicit keep rules, class/member merging is aggressive, and anything only
# reached reflectively or through JNI is removed. Every rule below exists
# because a plugin resolves something by name that R8 cannot see. Keep this list
# short and justified — a blanket `-keep class ** { *; }` would defeat shrinking.

# ---------------------------------------------------------------------------
# Flutter embedding and generated plugin registrant
# ---------------------------------------------------------------------------
# The engine calls into these classes from native code, and the generated
# registrant instantiates plugins by name.
-keep class io.flutter.** { *; }

# JNI resolves native methods by name; renaming them breaks the lookup.
-keepclasseswithmembernames class * {
    native <methods>;
}

# ---------------------------------------------------------------------------
# Gson — flutter_local_notifications
# ---------------------------------------------------------------------------
# The plugin serialises NotificationDetails and its scheduled-notification
# models with Gson and reads them back after a reboot. Gson resolves fields
# reflectively, so renaming or stripping them silently loses scheduled
# reminders and rest-timer notifications.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses,EnclosingMethod

# ---------------------------------------------------------------------------
# Tink — flutter_secure_storage
# ---------------------------------------------------------------------------
# The gateway API key is sealed with Tink's streaming AEAD. Tink loads key
# managers and primitive wrappers by class name.
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# ---------------------------------------------------------------------------
# Health Connect — health plugin
# ---------------------------------------------------------------------------
# Record and permission classes cross the Health Connect IPC boundary by name.
-keep class androidx.health.connect.client.** { *; }
-dontwarn androidx.health.connect.client.**

# ---------------------------------------------------------------------------
# Plugins reached only through platform channels or a native library
# ---------------------------------------------------------------------------
# No reflection here, but the entry points are looked up by name from the
# registrant and from JNI.
-keep class com.tekartik.sqflite.** { *; }
-keep class io.scer.pdf_renderer.** { *; }
-keep class io.scer.pdfx.** { *; }
-keep class xyz.luan.audioplayers.** { *; }
-keep class com.baseflow.permissionhandler.** { *; }
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class dev.fluttercommunity.plus.share.** { *; }

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------
# Keep line numbers so release stack traces stay readable in Play Console.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Optional annotations that are not on the runtime classpath.
-dontwarn org.jetbrains.annotations.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**

# Flutter's deferred-components support references Play Core, which is only on
# the classpath when the app actually uses deferred components. Compounder does
# not, so the references are dangling but never executed.
-dontwarn com.google.android.play.core.**
