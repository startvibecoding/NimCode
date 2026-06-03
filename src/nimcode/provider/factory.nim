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
  
  # Google Vertex
  if lower.contains("vertex") or lower.contains("aiplatform"):
    return "google-gemini"
  
  # Default to OpenAI chat completions
  return "openai-chat"

proc createProvider*(providerConfig: ProviderConfig, retrySettings: RetrySettings): Provider =
  ## Create a provider from config with auto-detection
  let apiKey = resolveKey(providerConfig)
  if apiKey == "":
    raise newException(CatchableError, "API key not set")
  
  let apiType = detectApiType(providerConfig.baseUrl, providerConfig.api)
  
  case apiType
  of "anthropic-messages":
    let p = newAnthropicProvider(apiKey, providerConfig.baseUrl,
      retryEnabled = retrySettings.enabled,
      maxRetries = retrySettings.maxRetries,
      baseDelayMs = retrySettings.baseDelayMs)
    if providerConfig.thinkingFormat != "":
      p.thinkingFormat = providerConfig.thinkingFormat
    if providerConfig.cacheControl:
      p.cacheControlEnabled = true
    return p
  
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
    if providerConfig.thinkingFormat != "":
      p.thinkingFormat = providerConfig.thinkingFormat
    return p
  
  else: # "openai-chat" or any other
    let p = newOpenAiProvider(apiKey, providerConfig.baseUrl,
      retryEnabled = retrySettings.enabled,
      maxRetries = retrySettings.maxRetries,
      baseDelayMs = retrySettings.baseDelayMs)
    if providerConfig.thinkingFormat != "":
      p.thinkingFormat = providerConfig.thinkingFormat
    return p

proc createProviderFromSettings*(settings: Settings, providerName: string): Provider =
  ## Create a provider from settings with full config resolution
  let pcOpt = settings.getProviderConfig(providerName)
  if pcOpt.isNone:
    raise newException(CatchableError, "Provider not found: " & providerName)
  return createProvider(pcOpt.get(), settings.retry)
