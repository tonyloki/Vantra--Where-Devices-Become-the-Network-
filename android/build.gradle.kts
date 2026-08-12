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
    project.evaluationDependsOn(":app")
}

subprojects {
    val forceCompileSdk = { proj: Project ->
        if (proj.hasProperty("android")) {
            val android = proj.extensions.findByName("android")
            if (android != null) {
                try {
                    val method = android.javaClass.getMethod("compileSdkVersion", Integer.TYPE)
                    method.invoke(android, 36)
                    println("[VANTRA][BUILD] Forced compileSdkVersion=36 for subproject: ${proj.name}")
                } catch (e: Exception) {
                    try {
                        val setMethod = android.javaClass.getMethod("setCompileSdkVersion", Integer.TYPE)
                        setMethod.invoke(android, 36)
                        println("[VANTRA][BUILD] Forced compileSdkVersion=36 via setCompileSdkVersion for subproject: ${proj.name}")
                    } catch (e2: Exception) {
                        // ignore
                    }
                }
            }
        }
    }

    if (project.state.executed) {
        forceCompileSdk(project)
    } else {
        project.afterEvaluate {
            forceCompileSdk(project)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
