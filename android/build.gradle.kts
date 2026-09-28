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
// mp_audio_stream 0.3.0 pins compileSdk 31, NDK 21 and minSdk 16 (android/build.gradle of the plugin):
// AGP rejects compileSdk 31 against the androidx AARs Flutter pulls in, and NDK 21 is obsolete
// (no 16 KB page alignment defaults). Build it with the app's SDK/NDK instead.
subprojects {
    val fixPlugin: (Project) -> Unit = { p ->
        if (p.name == "mp_audio_stream") {
            p.extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.apply {
                compileSdk = 36
                ndkVersion = "28.2.13676358"
                defaultConfig.minSdk = 24 // plugin says 16; NDK 28 needs >= 21 (app minSdk is 24)
            }
        }
    }
    if (state.executed) fixPlugin(this) else afterEvaluate { fixPlugin(this) }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
