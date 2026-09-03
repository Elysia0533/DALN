package com.vbook.reader.engine

open class VBookEngineException(
    val platformCode: String,
    message: String,
    cause: Throwable? = null,
) : RuntimeException(message, cause)

class JsExecutionTimeoutException(functionName: String) : VBookEngineException(
    platformCode = "EXEC_TIMEOUT",
    message = "Extension execution timed out while running '$functionName'.",
)

class JsNetworkException(cause: Throwable) : VBookEngineException(
    platformCode = "NETWORK_ERROR",
    message = "Extension network request failed.",
    cause = cause,
)

class JsScriptException(
    operation: String,
    cause: Throwable? = null,
) : VBookEngineException(
    platformCode = "JS_ERROR",
    message = "Extension JavaScript failed while running '$operation'.",
    cause = cause,
)

class JsResultParseException(
    operation: String,
    cause: Throwable? = null,
) : VBookEngineException(
    platformCode = "PARSE_ERROR",
    message = "Extension returned invalid data for '$operation'.",
    cause = cause,
)

class JsResourceLimitException(resource: String) : VBookEngineException(
    platformCode = "RESOURCE_LIMIT",
    message = "Extension exceeded the allowed $resource limit.",
)

class JsAsyncUnsupportedException : VBookEngineException(
    platformCode = "ASYNC_UNSUPPORTED",
    message = "This extension uses Promise/async, which the current Android JavaScript runtime cannot execute safely.",
)

class JsExecutionCancelledException : VBookEngineException(
    platformCode = "EXEC_CANCELLED",
    message = "Extension execution was cancelled because its source session changed.",
)

class JsEngineUnavailableException : VBookEngineException(
    platformCode = "ENGINE_UNAVAILABLE",
    message = "Extension execution is disabled until the source is reloaded.",
)
