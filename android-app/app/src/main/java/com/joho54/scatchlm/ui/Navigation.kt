package com.joho54.scatchlm.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.joho54.scatchlm.ScatchLMApp
import com.joho54.scatchlm.ui.home.HomeScreen
import com.joho54.scatchlm.ui.login.LoginScreen
import com.joho54.scatchlm.ui.note.NoteScreen
import com.joho54.scatchlm.ui.pdf.PdfViewerScreen
import kotlinx.coroutines.flow.StateFlow

object Routes {
    const val LOGIN = "login"
    const val HOME = "home"
    const val NOTE = "note/{noteId}"
    const val PDF = "pdf/{textbookId}?noteId={noteId}"

    fun note(noteId: String) = "note/$noteId"
    fun pdf(textbookId: String, noteId: String? = null) =
        "pdf/$textbookId" + (noteId?.let { "?noteId=$it" } ?: "")
}

@Composable
fun AppNavHost(isAuthenticated: StateFlow<Boolean>) {
    val navController = rememberNavController()
    val authed by isAuthenticated.collectAsState()

    NavHost(
        navController = navController,
        startDestination = if (authed) Routes.HOME else Routes.LOGIN
    ) {
        composable(Routes.LOGIN) {
            LoginScreen(onAuthenticated = {
                navController.navigate(Routes.HOME) {
                    popUpTo(Routes.LOGIN) { inclusive = true }
                }
            })
        }

        composable(Routes.HOME) {
            HomeScreen(
                onOpenNote = { noteId -> navController.navigate(Routes.note(noteId)) },
                onSignedOut = {
                    navController.navigate(Routes.LOGIN) {
                        popUpTo(Routes.HOME) { inclusive = true }
                    }
                }
            )
        }

        composable(
            route = Routes.NOTE,
            arguments = listOf(navArgument("noteId") { type = NavType.StringType })
        ) { backStack ->
            val noteId = backStack.arguments?.getString("noteId") ?: return@composable
            NoteScreen(
                noteId = noteId,
                onBack = { navController.popBackStack() },
                onOpenPdf = { textbookId ->
                    navController.navigate(Routes.pdf(textbookId, noteId))
                }
            )
        }

        composable(
            route = Routes.PDF,
            arguments = listOf(
                navArgument("textbookId") { type = NavType.StringType },
                navArgument("noteId") {
                    type = NavType.StringType; nullable = true; defaultValue = null
                }
            )
        ) { backStack ->
            val textbookId = backStack.arguments?.getString("textbookId") ?: return@composable
            val noteId = backStack.arguments?.getString("noteId")
            PdfViewerScreen(
                textbookId = textbookId,
                noteId = noteId,
                onBack = { navController.popBackStack() }
            )
        }
    }
}
