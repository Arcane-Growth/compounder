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
    // Align every plugin on the app's compileSdk. Plugins that pin an older
    // compileSdk are raised to it; plugins that need a newer one (for example
    // permission_handler_android 14.x, which references API 37 constants such
    // as Manifest.permission.ACCESS_LOCAL_NETWORK and
    // Build.VERSION_CODES.CINNAMON_BUN) must not be lowered below it, or their
    // Java sources fail to compile. Keep this in lockstep with
    // android/app/build.gradle.kts.
    // (:app is force-evaluated below and already targets the app compileSdk.)
    if (project.name != "app") {
        afterEvaluate {
            extensions.findByName("android")?.withGroovyBuilder {
                setProperty("compileSdk", 37)
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
