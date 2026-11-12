pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

rootProject.name = "bitchord-apple"

include(":shared")

include(":innertubex")
project(":innertubex").projectDir = file("vendor/innertubex")

include(":quackjs")
project(":quackjs").projectDir = file("vendor/quackjs")
