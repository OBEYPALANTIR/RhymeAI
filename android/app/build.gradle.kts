import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.isFile) {
        localPropertiesFile.inputStream().use(::load)
    }
}
val geminiTestKey = localProperties.getProperty("geminiTestKey", "")
val includeGeminiTestKey = providers.gradleProperty("includeGeminiTestKey")
    .orNull
    ?.toBooleanStrictOrNull()
    ?: false
val embeddedGeminiTestKey = if (includeGeminiTestKey) geminiTestKey else ""
val rewriteMotionStyleProperty = providers.gradleProperty("rewriteMotionStyle")
val rewriteMotionStyle = rewriteMotionStyleProperty
    .getOrElse("ripple")
val rewriteMotionStyles = setOf("pencil", "ripple", "paper")
if (rewriteMotionStyle !in rewriteMotionStyles) {
    throw GradleException(
        "rewriteMotionStyle must be one of ${rewriteMotionStyles.sorted().joinToString()}, got '$rewriteMotionStyle'"
    )
}
// Optional OAuth web client id for the Drive appData integration. If absent, the
// Android installed-app flow proceeds without a server client id (which is fine for
// device-only sync). Set in android/local.properties as: driveOauthClientId=<value>
val driveOauthClientId = localProperties.getProperty("driveOauthClientId", "")
fun buildConfigString(value: String): String = "\"${value.replace("\\", "\\\\").replace("\"", "\\\"")}\""

val keystoreProperties = Properties().apply {
    val keystorePropertiesFile = rootProject.file("keystore.properties")
    if (keystorePropertiesFile.isFile) {
        keystorePropertiesFile.inputStream().use(::load)
    }
}

fun Properties.nonBlankProperty(name: String): String? =
    getProperty(name)?.takeIf { it.isNotBlank() }

fun env(name: String): String? =
    System.getenv(name)?.takeIf { it.isNotBlank() }

fun Map<String, String?>.completeSigningProperties(): Map<String, String>? =
    takeIf { values.all { value -> value.isNullOrBlank().not() } }?.mapValues { it.value.orEmpty() }

val releaseSigningProperties = mapOf(
    "storeFile" to (keystoreProperties.nonBlankProperty("storeFile") ?: env("RHYMEAI_KEYSTORE_FILE")),
    "storePassword" to (keystoreProperties.nonBlankProperty("storePassword") ?: env("RHYMEAI_STORE_PASSWORD")),
    "keyAlias" to (keystoreProperties.nonBlankProperty("keyAlias") ?: env("RHYMEAI_KEY_ALIAS")),
    "keyPassword" to (keystoreProperties.nonBlankProperty("keyPassword") ?: env("RHYMEAI_KEY_PASSWORD")),
).completeSigningProperties()
val releaseStoreFile = releaseSigningProperties?.get("storeFile")?.let { rootProject.file(it) }
val hasReleaseSigningConfig = releaseSigningProperties != null && releaseStoreFile?.isFile == true

tasks.configureEach {
    // bundleRelease (Play upload) still demands real signing material.
    // assembleRelease falls back to the debug key so optimized builds can be
    // side-loaded for performance testing without a production keystore.
    if (name == "bundleRelease") {
        doFirst {
            if (!hasReleaseSigningConfig) {
                throw GradleException("Release signing material missing: create android/keystore.properties")
            }
        }
    }
}

android {
    namespace = "com.rhymeai.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.rhymeai.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 3
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "REWRITE_MOTION_STYLE", buildConfigString(rewriteMotionStyle))
        buildConfigField(
            "boolean",
            "REWRITE_MOTION_STYLE_IS_OVERRIDE",
            rewriteMotionStyleProperty.isPresent.toString()
        )
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    if (hasReleaseSigningConfig) {
        val signingValues = requireNotNull(releaseSigningProperties)
        val signingStoreFile = requireNotNull(releaseStoreFile)
        signingConfigs {
            create("release") {
                storeFile = signingStoreFile
                storePassword = signingValues.getValue("storePassword")
                keyAlias = signingValues.getValue("keyAlias")
                keyPassword = signingValues.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            versionNameSuffix = "-$rewriteMotionStyle"
            buildConfigField("String", "GEMINI_TEST_KEY", buildConfigString(embeddedGeminiTestKey))
            buildConfigField("String", "DRIVE_OAUTH_CLIENT_ID", buildConfigString(driveOauthClientId))
        }
        release {
            isMinifyEnabled = true
            if (rewriteMotionStyleProperty.isPresent) {
                versionNameSuffix = "-$rewriteMotionStyle-eval"
            }
            signingConfig = if (hasReleaseSigningConfig) {
                signingConfigs.getByName("release")
            } else {
                // Debug-key fallback: installable for local testing; not for Play.
                signingConfigs.getByName("debug")
            }
            buildConfigField("String", "GEMINI_TEST_KEY", buildConfigString(""))
            buildConfigField("String", "DRIVE_OAUTH_CLIENT_ID", buildConfigString(driveOauthClientId))
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    sourceSets {
        getByName("main") {
            assets.srcDir("../../shared/pronunciation")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.core:core-splashscreen:1.0.1")
    implementation("androidx.activity:activity-compose:1.9.3")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.navigation:navigation-compose:2.8.5")

    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("androidx.security:security-crypto:1.1.0")

    implementation("com.google.ai.client.generativeai:generativeai:0.7.0")

    // On-device LLM inference (GGUF support via llama.cpp)
    implementation("io.github.ljcamargo:llamacpp-kotlin:0.4.0")

    // OAuth for Drive appData scope; Drive REST calls use HttpURLConnection (same
    // idiom as AIService) — no heavy Google API client library needed.
    implementation("com.google.android.gms:play-services-auth:21.3.0")

    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation(kotlin("test"))

    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
