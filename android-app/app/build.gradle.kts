plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

android {
    namespace = "com.joho54.scatchlm"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.joho54.scatchlm"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables { useSupportLibrary = true }

        // Supabase (iOS Config.swift 와 동일 값)
        buildConfigField("String", "SUPABASE_URL", "\"https://iuuhjgnlxzakdrsuobuh.supabase.co\"")
        buildConfigField(
            "String",
            "SUPABASE_ANON_KEY",
            "\"sb_publishable_tpIT1v44gNDeooIndTnfeQ__cUr3EGo\""
        )
    }

    buildTypes {
        debug {
            // 개발 서버. iOS 는 :18000 (backend/Makefile:8). 실기기에서 접근하려면
            // Mac 의 LAN IP 로 바꿀 것 (예: 10.0.2.2 는 에뮬레이터 → 호스트 루프백).
            buildConfigField("String", "API_BASE_URL", "\"http://10.0.2.2:18000/api\"")
        }
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            buildConfigField("String", "API_BASE_URL", "\"https://scatchlm.duckdns.org/api\"")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    // Core / Compose
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    debugImplementation(libs.androidx.ui.tooling)

    // Room
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)

    // Network
    implementation(libs.retrofit)
    implementation(libs.retrofit.kotlinx.serialization)
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.kotlinx.serialization.json)

    // 인증: Supabase GoTrue REST API 직접 호출 (OkHttp + kotlinx.serialization)
    // supabase-kt(KMP) 대신 경량 REST 사용 — 백엔드는 유효한 Supabase JWT 만 필요

    // 드로잉: Compose Canvas + 스타일러스 입력 직접 처리 (스펙 §7 폴백, 의존성 0)
    // TODO: Jetpack Ink(androidx.ink) 안정화 시 InkCanvas 내부 엔진 교체 (§6.x-1)

    // PDF: 빌트인 android.graphics.pdf.PdfRenderer 사용 (추가 의존성 없음)

    // Markdown
    implementation(libs.compose.markdown)

    // Test
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
}
