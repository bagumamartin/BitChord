// BitChord shared KMP module — spec §1.
// Apple-only targets for now; androidMain exists as a dormant placeholder for
// the future Android reunification (§10 non-goals).
import java.util.Properties
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
    id("com.rickclephas.kmp.nativecoroutines")
}

kotlin {
    // One combined XCFramework consumed by AppleApp (spec §1.1).
    val xcf = XCFramework("BitChordShared")

    listOf(
        iosArm64(),
        iosSimulatorArm64(),
        macosArm64(),
        // Add macosX64()/iosX64() only if Intel support becomes a requirement (§1.1).
    ).forEach { target ->
        target.binaries.framework {
            baseName = "BitChordShared"
            binaryOption("bundleId", "app.bitchord.BitChord.shared")
            isStatic = true
            xcf.add(this)
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(project(":innertubex"))
            implementation("io.ktor:ktor-client-core:3.6.0")
            implementation("io.ktor:ktor-client-content-negotiation:3.6.0")
            implementation("io.ktor:ktor-serialization-kotlinx-json:3.6.0")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
            implementation("com.rickclephas.kmp:kmp-nativecoroutines-core:1.0.5")
            // sqldelight: add only if upstream Room usage is confirmed (spec §1.1).
        }

        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation("io.ktor:ktor-client-mock:3.6.0")
            // For `runTest` only. Kotlin/Native's `kotlin.test` refuses a `suspend`
            // test function outright, and a `@Test` that blocks the test thread
            // instead is how a suspended read deadlocks in CI rather than in a
            // screenshot.
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
        }

        // The Darwin Ktor engine only resolves for Apple targets, so it lives in
        // appleMain — the common ancestor of every configured Apple target.
        appleMain.dependencies {
            implementation("io.ktor:ktor-client-darwin:3.6.0")
            // The party socket is NSURLSessionWebSocketTask, not Ktor: Ktor 3.2's
            // client websockets plugin is an empty shell on Darwin, and the platform
            // API is both shorter and gives the close code and ping/pong this
            // protocol needs.
        }
    }
}

// ---- Build-time configuration ---------------------------------------------
//
// Kept out of the source tree on purpose. A build-time value is the one kind of
// configuration that gets baked into every install and cannot be corrected by the
// person running it, so it has to be something the *distributor* chose on purpose
// rather than something a developer left lying around in a committed file.
//
// Both sources below are gitignored or outside the repository, so a fresh checkout
// gets the empty default. See `BuildDefaults.kt` for what an empty one means.
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

/** A party server to bake in. Empty means "the listener must supply one". */
val listenTogetherServer: String = (
    localProps.getProperty("LISTEN_TOGETHER_SERVER")
        ?: System.getenv("LISTEN_TOGETHER_SERVER")
        ?: ""
    ).trim()

// Escaped for a Kotlin string literal, because a server address reaches this file
// from a text file a person edited and `\` or `"` in it must not become a syntax
// error in generated code.
val escaped = listenTogetherServer.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\${'$'}")

val generatedDir = layout.buildDirectory.dir("generated/listentogether").get().asFile
val generateDefaults by tasks.registering {
    val out = File(generatedDir, "com/music/bitchord/BuildDefaults.kt")
    val localFile = rootProject.file("local.properties")
    // Declared as an input, which it was not, and the consequence was that editing
    // `local.properties` did nothing: the task had an output and no inputs, so Gradle
    // considered it up to date and the address kept whatever it was generated with.
    // That is the worst possible failure for this file — a build-time value that
    // silently refuses to change, so a distributor who removes a server ships the
    // server anyway. A missing file is a legitimate input state, not an error: the
    // empty default is the shipped one. `files` rather than `file(...).optional()`:
    // Gradle validates a single-file input as existing even when it is optional, so
    // a fresh checkout failed here; a file collection may name a file that is absent.
    inputs.files(localFile)
    inputs.property("listenTogetherServer", listenTogetherServer)
    outputs.file(out)
    doLast {
        out.parentFile.mkdirs()
        out.writeText(
            """
            |// GENERATED by shared/build.gradle.kts — do not edit, do not commit.
            |package com.music.bitchord
            |
            |/** Build-time configuration. See `shared/build.gradle.kts` for where each value comes from. */
            |object BuildDefaults {
            |    /**
            |     * The party server baked into this build, or an empty string when the
            |     * distributor chose not to name one.
            |     *
            |     * Empty is the shipped default on purpose. A party server is a
            |     * deployment somebody has to run and keep running, and naming one
            |     * here means every install on this build is coupled to its uptime and
            |     * its address. So the default is to ask the listener for theirs, which
            |     * is also the only value that keeps working when they change it.
            |     */
            |    const val LISTEN_TOGETHER_SERVER: String = "$escaped"
            |}
            |
            """.trimMargin(),
        )
    }
}

kotlin.sourceSets.commonMain.get().kotlin.srcDir(generatedDir)

// Every Kotlin compile in this module, by name: the klib-metadata task this
// project used to have no longer exists under that name, and a task that fails to
// resolve fails the *configuration*, not just a build.
tasks.matching { it.name.startsWith("compile") && it.name.contains("Kotlin") }
    .configureEach { dependsOn(generateDefaults) }
