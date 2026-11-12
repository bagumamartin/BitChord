plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
}

kotlin {
    iosArm64(); iosSimulatorArm64(); macosArm64()
    sourceSets {
        all { languageSettings.optIn("kotlin.RequiresOptIn"); languageSettings.optIn("kotlin.ExperimentalStdlibApi") }
        commonMain.dependencies {
            api("io.ktor:ktor-client-core:3.6.0")
            api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
            api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            implementation(project(":quackjs"))
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation("io.ktor:ktor-client-mock:3.6.0")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
            implementation("io.ktor:ktor-client-content-negotiation:3.6.0")
            implementation("io.ktor:ktor-serialization-kotlinx-json:3.6.0")
        }
    }
    targets.all { compilations.all { compileTaskProvider.configure {
        compilerOptions.freeCompilerArgs.add("-Xexpect-actual-classes")
    } } }
}
