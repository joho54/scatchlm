package com.joho54.scatchlm

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.joho54.scatchlm.ui.AppNavHost
import com.joho54.scatchlm.ui.theme.ScatchLMTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            ScatchLMTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    AppNavHost(isAuthenticated = ScatchLMApp.auth.isAuthenticated)
                }
            }
        }
    }
}
