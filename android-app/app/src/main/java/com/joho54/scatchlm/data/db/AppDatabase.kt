package com.joho54.scatchlm.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [
        NoteEntity::class,
        NotePageEntity::class,
        FeedbackEntity::class,
        ChatMessageEntity::class,
        PdfDrawingEntity::class,
    ],
    version = 1,
    exportSchema = true
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun noteDao(): NoteDao
    abstract fun notePageDao(): NotePageDao
    abstract fun feedbackDao(): FeedbackDao
    abstract fun chatMessageDao(): ChatMessageDao
    abstract fun pdfDrawingDao(): PdfDrawingDao

    companion object {
        fun build(context: Context): AppDatabase =
            Room.databaseBuilder(context, AppDatabase::class.java, "scatchlm.db")
                // FK CASCADE 동작을 위해 외래키 강제
                .build()
    }
}
