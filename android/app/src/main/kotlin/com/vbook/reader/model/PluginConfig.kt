package com.vbook.reader.model

import kotlinx.serialization.Serializable

@Serializable
data class PluginConfig(
    val metadata: Metadata,
    val script: ScriptConfig
)

@Serializable
data class Metadata(
    val name: String,
    val author: String? = null,
    val version: kotlinx.serialization.json.JsonElement? = null,
    val versionCode: Int? = null,
    val source: String? = null,
    val regexp: String? = null,
    val description: String? = null,
    val locale: String? = null,
    val language: String? = null,
    val tag: String? = null,
    val type: String? = null,
    val encrypt: Boolean? = false
) {
    /**
     * VBook plugin.json nội tại dùng "version": 14 (số nguyên).
     * Giá trị version có thể được gản dưới dạng Int và bị coerce thành String
     * do ignoreUnknownKeys + coerceInputValues = true trong JsLoader.json config.
     * Để an toàn, lấy versioCode từ version nếu versionCode null.
     */
    fun resolvedVersionCode(): Long {
        return versionCode?.toLong()
            ?: version?.let { 
                if (it is kotlinx.serialization.json.JsonPrimitive) it.content.toLongOrNull() 
                else null 
            }
            ?: 1L
    }

    fun resolvedVersionName(): String {
        return version?.let { 
            if (it is kotlinx.serialization.json.JsonPrimitive) it.content 
            else null 
        } ?: versionCode?.toString() ?: "1.0"
    }
}

@Serializable
data class ScriptConfig(
    val home: String? = null,
    val genre: String? = null,
    val detail: String? = null,
    val search: String? = null,
    val page: String? = null,
    val toc: String? = null,
    val chap: String? = null
)
