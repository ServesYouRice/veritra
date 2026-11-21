allprojects {
    repositories {
        google()
        mavenCentral()
    }

    // Dependency locking (docs/release-engineering.md). Gradle's default lock
    // mode: a configuration with a lock state must resolve exactly to it, and
    // one without (no lockfile committed yet) resolves as before, so this is
    // inert until scripts/gradle-lock.sh writes gradle/locks/. Every project
    // keeps its lockfile in this repository; the Flutter plugin projects live
    // in the pub cache, where a default lockfile would never be committed.
    dependencyLocking {
        lockAllConfigurations()
        lockFile.set(rootProject.layout.projectDirectory.file("gradle/locks/${project.name}.lockfile"))
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
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
