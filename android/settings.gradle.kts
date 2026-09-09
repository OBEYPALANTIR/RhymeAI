pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "RhymeAI"
include(":app")
include(":kotlinllamacpp")
project(":kotlinllamacpp").projectDir = file("third_party/kotlinllamacpp")
