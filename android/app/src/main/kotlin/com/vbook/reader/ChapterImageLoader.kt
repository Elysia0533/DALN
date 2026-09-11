package com.vbook.reader

import java.io.ByteArrayOutputStream
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

internal class ChapterImageLoader(private val client: OkHttpClient) {
    companion object {
        const val MAX_BYTES = 16 * 1024 * 1024
        const val USER_AGENT = "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    }

    fun load(value: String, referer: String): ByteArray {
        val url = value.toHttpUrlOrNull() ?: error("Invalid image URL")
        require(url.username.isEmpty() && url.password.isEmpty())
        val request = Request.Builder().url(url).header("User-Agent", USER_AGENT)
        referer.toHttpUrlOrNull()?.takeIf {
            it.username.isEmpty() && it.password.isEmpty()
        }?.let { request.header("Referer", it.toString()) }
        client.newCall(request.build()).execute().use { response ->
            check(response.isSuccessful)
            val body = response.body ?: error("Empty image response")
            require(body.contentLength() <= MAX_BYTES)
            val type = body.contentType()?.toString().orEmpty()
            require(!type.startsWith("text/") && !type.contains("json"))
            val output = ByteArrayOutputStream()
            body.byteStream().use { input ->
                val chunk = ByteArray(8192)
                while (true) {
                    val count = input.read(chunk)
                    if (count < 0) break
                    require(output.size() + count <= MAX_BYTES)
                    output.write(chunk, 0, count)
                }
            }
            check(output.size() > 0)
            return output.toByteArray()
        }
    }
}
