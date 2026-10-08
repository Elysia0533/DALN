package eu.kanade.tachiyomi.source.model

data class Page(
    val index: Int,
    val url: String = "",
    var imageUrl: String? = null,
    @Transient var status: Int = READY
) {
    companion object {
        const val QUEUE = 0
        const val LOAD_PAGE = 1
        const val DOWNLOAD_IMAGE = 2
        const val READY = 3
        const val ERROR = 4
    }
}

data class MangasPage(val mangas: List<SManga>, val hasNextPage: Boolean)

class FilterList(vararg filters: Filter<*>) : List<Filter<*>> by filters.toList()

sealed class Filter<T>(val name: String, var state: T)
