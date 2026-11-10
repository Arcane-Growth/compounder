allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    // Raise plugins that pin an older compileSdk to API 37, but never lower a
    // plugin that already declares a newer one: permission_handler_android
    // 14.x references API 37 constants (Manifest.permission.ACCESS_LOCAL_NETWORK,
    // Build.VERSION_CODES.CINNAMON_BUN), so forcing it down to Flutter's
    // default 36 breaks its Java sources, and a plugin on 38 would break the
    // same way. Keep the 37 floor in lockstep with android/app/build.gradle.kts.
    // (:app is force-evaluated below and already targets the app compileSdk.)
    if (project.name != "app") {
        afterEvaluate {
            val androidExt = extensions.findByName("android") ?: return@afterEvaluate
            val declared =
                runCatching {
                    androidExt.withGroovyBuilder { getProperty("compileSdk") } as? Int
                }.getOrNull()
            if (declared == null || declared < 37) {
                androidExt.withGroovyBuilder { setProperty("compileSdk", 37) }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
