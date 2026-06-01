package com.joho54.scatchlm.ui.login

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.joho54.scatchlm.ScatchLMApp
import kotlinx.coroutines.launch

@Composable
fun LoginScreen(onAuthenticated: () -> Unit) {
    val auth = ScatchLMApp.auth
    val scope = rememberCoroutineScope()

    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var isSignUp by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("ScatchLM", style = androidx.compose.material3.MaterialTheme.typography.headlineLarge)

        OutlinedTextField(
            value = email,
            onValueChange = { email = it },
            label = { Text("Email") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
            modifier = Modifier.width(360.dp).padding(top = 24.dp),
        )
        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            label = { Text("Password") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            modifier = Modifier.width(360.dp).padding(top = 12.dp),
        )

        error?.let {
            Text(
                it,
                color = androidx.compose.material3.MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 12.dp),
            )
        }

        Button(
            onClick = {
                loading = true
                error = null
                scope.launch {
                    runCatching {
                        if (isSignUp) auth.signUp(email.trim(), password)
                        else auth.signIn(email.trim(), password)
                    }.onSuccess {
                        loading = false
                        onAuthenticated()
                    }.onFailure {
                        loading = false
                        error = it.message ?: "Authentication failed"
                    }
                }
            },
            enabled = !loading && email.isNotBlank() && password.isNotBlank(),
            modifier = Modifier.width(360.dp).padding(top = 20.dp),
        ) {
            if (loading) CircularProgressIndicator(modifier = Modifier.width(20.dp))
            else Text(if (isSignUp) "Sign Up" else "Sign In")
        }

        TextButton(onClick = { isSignUp = !isSignUp }, enabled = !loading) {
            Text(if (isSignUp) "이미 계정이 있으신가요? 로그인" else "계정이 없으신가요? 회원가입")
        }
    }
}
