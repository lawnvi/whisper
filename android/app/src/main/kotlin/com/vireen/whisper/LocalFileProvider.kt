package com.vireen.whisper

import androidx.core.content.FileProvider

/**
 * Hands a local file, such as a received one under /Download/whisper, to the
 * app the user picks to open it. A class of its own so its manifest entry and
 * authority stay apart from the provider that stages system shares.
 */
class LocalFileProvider : FileProvider()
