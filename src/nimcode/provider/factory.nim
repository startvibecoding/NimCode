import std/[strutils, os, tables, options]
import ./types
import ./openai
import ./anthropic
import ./google
import ../config/config

## Provider factory with vendor auto-detection.
## Matches vibecoding's provider resolution strategy:
## 1. Explicit `api` field in config
## 2. Auto-detect from baseUrl domains
## 3. Default to openai-chat

proc detectApiType*(baseUrl: string, api: string): string =
  ## Resolve the API type from explicit config or baseUrl auto-detection
  if api != "":
    return api
  
  let lower = baseUrl.toLower
  
  # Anthropic
  if lower.contains("anthropic"):
    return "anthropic-messages"
  
  # Google Gemini
  if lower.contains("google") or lower.contains("gemini") or lower.contains("generativelanguage"):
    return "google-gemini"
  
  # OpenAI Responses API (for o1/o3 with reasoning)
  # Default to chat completions
  return "openai-chat"

proc createProvider*(providerConfig: ProviderConfig, retrySettings: RetrySettings): Provider =
  ## Create a provider from config with auto-detection
  let apiKey = resolveKey(providerConfig)
  if apiKey == "":
    raise newException(CatchableError, "API key not set")
  
  let apiType = detectApiType(providerConfig.baseUrl, providerConfig.api)
  
  case apiType
  of "anthropic-messages":
    return newAnthropicProvider(apiKey, providerConfig.baseUrl,
      retryEnabled = retrySettings.enabled,
      maxRetries = retrySettings.maxRetries,
      baseDelayMs = retrySettings.baseDelayMs)
  
  of "google-gemini":
    return newGoogleGeminiProvider(apiKey, providerConfig.baseUrl,
      retryEnabled = retrySettings.enabled,
      maxRetries = retrySettings.maxRetries,
      baseDelayMs = retrySettings.baseDelayMs)
  
  of "openai-responses":
    let p = newOpenAiProvider(apiKey, providerConfig.baseUrl,
      retryEnabled = retrySettings.enabled,
      maxRetries = retrySettings.maxRetries,
      baseDelayMs = retrySettings.baseDelayMs)
    p.useResponsesApi = true
    return p
  
  else: # "openai-chat" or any other
    return newOpenAiProvider(apiKey, providerConfig.baseUrl,
      retryEnabled = retrySettings.enabled,
      maxRetries = retrySettings.maxRetries,
      baseDelayMs = retrySettings.baseDelayMs)
