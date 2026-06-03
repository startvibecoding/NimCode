import std/[json, os, strutils, options, tables]

type
  ModelConfig* = object
    id*: string
    name*: string
    reasoning*: bool
    contextWindow*: int
    maxTokens*: int

  ProviderConfig* = object
    apiKey*: string
    baseUrl*: string
    api*: string
    models*: seq[ModelConfig]

  ApprovalSettings* = object
    bashWhitelist*: seq[string]  ## Command prefixes that auto-approve in agent mode
    bashBlacklist*: seq[string]  ## Command prefixes that always require approval

  Settings* = ref object
    providers*: Table[string, ProviderConfig]
    defaultProvider*: string
    defaultModel*: string
    defaultMode*: string
    defaultThinkingLevel*: string
    maxContextTokens*: int
    maxOutputTokens*: int
    approval*: ApprovalSettings

proc configDir*(): string =
  let home = getHomeDir()
  result = home / ".nimcode"

proc globalSettingsPath*(): string =
  configDir() / "settings.json"

proc projectSettingsPath*(): string =
  ".nimcode" / "settings.json"

proc resolveKey*(provider: ProviderConfig): string =
  ## Resolve API key, supporting ${VAR} syntax
  result = provider.apiKey
  if result.startsWith("${") and result.endsWith("}"):
    let envName = result[2 .. ^2]
    result = getEnv(envName, "")

proc defaultSettings*(): Settings =
  new(result)
  result = Settings(
    providers: {
      "openai": ProviderConfig(
        apiKey: "${OPENAI_API_KEY}",
        baseUrl: "https://api.openai.com/v1",
        api: "openai-chat",
        models: @[
          ModelConfig(id: "gpt-4o", name: "GPT-4o", contextWindow: 128000, maxTokens: 16384),
          ModelConfig(id: "gpt-4o-mini", name: "GPT-4o Mini", contextWindow: 128000, maxTokens: 16384),
        ]
      ),
      "anthropic": ProviderConfig(
        apiKey: "${ANTHROPIC_API_KEY}",
        baseUrl: "https://api.anthropic.com",
        api: "anthropic-messages",
        models: @[
          ModelConfig(id: "claude-sonnet-4-20250514", name: "Claude 4 Sonnet", reasoning: true, contextWindow: 200000, maxTokens: 16384),
          ModelConfig(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", contextWindow: 200000, maxTokens: 8192),
          ModelConfig(id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", contextWindow: 200000, maxTokens: 8192),
        ]
      ),
      "deepseek": ProviderConfig(
        apiKey: "${DEEPSEEK_API_KEY}",
        baseUrl: "https://api.deepseek.com",
        api: "openai-chat",
        models: @[
          ModelConfig(id: "deepseek-chat", name: "DeepSeek Chat", contextWindow: 128000, maxTokens: 8192),
          ModelConfig(id: "deepseek-reasoner", name: "DeepSeek Reasoner", reasoning: true, contextWindow: 128000, maxTokens: 8192),
        ]
      ),
      "google-gemini": ProviderConfig(
        apiKey: "${GOOGLE_API_KEY}",
        baseUrl: "https://generativelanguage.googleapis.com/v1beta/models",
        api: "google-gemini",
        models: @[
          ModelConfig(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", reasoning: true, contextWindow: 1000000, maxTokens: 65536),
          ModelConfig(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", reasoning: true, contextWindow: 1000000, maxTokens: 65536),
        ]
      ),
    }.toTable,
    defaultProvider: "deepseek",
    defaultModel: "deepseek-chat",
    defaultMode: "agent",
    defaultThinkingLevel: "medium",
    maxContextTokens: 128000,
    maxOutputTokens: 8192,
    approval: ApprovalSettings(
      bashWhitelist: @["go ", "make ", "git ", "nim ", "nimble "],
      bashBlacklist: @[]
    ),
  )

proc settingsToJson(settings: Settings): JsonNode =
  ## Convert settings to JSON
  result = newJObject()
  
  # Providers
  var providers = newJObject()
  for name, provider in settings.providers:
    var providerJson = newJObject()
    providerJson["apiKey"] = %provider.apiKey
    providerJson["baseUrl"] = %provider.baseUrl
    providerJson["api"] = %provider.api
    
    var models = newJArray()
    for model in provider.models:
      models.add(%*{
        "id": model.id,
        "name": model.name,
        "reasoning": model.reasoning,
        "contextWindow": model.contextWindow,
        "maxTokens": model.maxTokens
      })
    providerJson["models"] = models
    providers[name] = providerJson
  
  result["providers"] = providers
  result["defaultProvider"] = %settings.defaultProvider
  result["defaultModel"] = %settings.defaultModel
  result["defaultMode"] = %settings.defaultMode
  result["defaultThinkingLevel"] = %settings.defaultThinkingLevel
  result["maxContextTokens"] = %settings.maxContextTokens
  result["maxOutputTokens"] = %settings.maxOutputTokens
  
  # Approval settings
  result["approval"] = %*{
    "bashWhitelist": settings.approval.bashWhitelist,
    "bashBlacklist": settings.approval.bashBlacklist
  }

proc ensureConfigExists(defaults: Settings) =
  ## Ensures the config directory and settings file exist
  let dir = configDir()
  let settingsPath = globalSettingsPath()
  
  if fileExists(settingsPath):
    return
  
  try:
    createDir(dir)
    let data = defaults.settingsToJson()
    writeFile(settingsPath, data.pretty())
    stderr.writeLine("Created default config: " & settingsPath)
  except CatchableError as e:
    stderr.writeLine("Warning: could not create config: " & e.msg)

proc ensureProjectConfigExists*() =
  ## Ensures the project config directory exists
  let dir = ".nimcode"
  if not dirExists(dir):
    try:
      createDir(dir)
    except:
      discard

proc parseProviders(data: JsonNode): Table[string, ProviderConfig] =
  ## Parse providers from JSON data
  result = initTable[string, ProviderConfig]()
  if not data.hasKey("providers"): return
  let providersNode = data["providers"]
  for name, pNode in providersNode:
    var pc = ProviderConfig()
    if pNode.hasKey("apiKey"):
      pc.apiKey = pNode["apiKey"].getStr("")
    if pNode.hasKey("baseUrl"):
      pc.baseUrl = pNode["baseUrl"].getStr("")
    if pNode.hasKey("api"):
      pc.api = pNode["api"].getStr("")
    pc.models = @[]
    if pNode.hasKey("models"):
      for mNode in pNode["models"]:
        var mc = ModelConfig()
        mc.id = mNode{"id"}.getStr("")
        mc.name = mNode{"name"}.getStr("")
        mc.reasoning = mNode{"reasoning"}.getBool(false)
        mc.contextWindow = mNode{"contextWindow"}.getInt(0)
        mc.maxTokens = mNode{"maxTokens"}.getInt(0)
        pc.models.add(mc)
    result[name] = pc

proc loadSettings*(): Settings =
  result = defaultSettings()
  
  # Ensure config exists
  ensureConfigExists(result)

  # Load global settings
  let globalPath = globalSettingsPath()
  if fileExists(globalPath):
    try:
      let data = parseFile(globalPath)
      # Merge global settings
      if data.hasKey("defaultProvider"):
        result.defaultProvider = data["defaultProvider"].getStr()
      if data.hasKey("defaultModel"):
        result.defaultModel = data["defaultModel"].getStr()
      if data.hasKey("defaultMode"):
        result.defaultMode = data["defaultMode"].getStr()
      if data.hasKey("defaultThinkingLevel"):
        result.defaultThinkingLevel = data["defaultThinkingLevel"].getStr()
      if data.hasKey("maxContextTokens"):
        result.maxContextTokens = data["maxContextTokens"].getInt()
      if data.hasKey("maxOutputTokens"):
        result.maxOutputTokens = data["maxOutputTokens"].getInt()
      # Parse providers
      let parsed = parseProviders(data)
      if parsed.len > 0:
        result.providers = parsed
    except:
      discard

  # Load project settings (overrides global)
  let projectPath = projectSettingsPath()
  if fileExists(projectPath):
    try:
      let data = parseFile(projectPath)
      if data.hasKey("defaultProvider"):
        result.defaultProvider = data["defaultProvider"].getStr()
      if data.hasKey("defaultModel"):
        result.defaultModel = data["defaultModel"].getStr()
      if data.hasKey("defaultMode"):
        result.defaultMode = data["defaultMode"].getStr()
      # Project providers merge/override global
      let parsed = parseProviders(data)
      if parsed.len > 0:
        for name, pc in parsed:
          result.providers[name] = pc
    except:
      discard

  # Environment variable overrides
  let envProvider = getEnv("NIMCODE_PROVIDER", "")
  if envProvider != "":
    result.defaultProvider = envProvider

  let envModel = getEnv("NIMCODE_MODEL", "")
  if envModel != "":
    result.defaultModel = envModel

proc getProviderConfig*(settings: Settings, name: string): Option[ProviderConfig] =
  if settings.providers.hasKey(name):
    return some(settings.providers[name])
  return none(ProviderConfig)

proc getModelConfig*(settings: Settings, providerName, modelId: string): Option[ModelConfig] =
  let providerOpt = settings.getProviderConfig(providerName)
  if providerOpt.isNone:
    return none(ModelConfig)
  let provider = providerOpt.get()
  for m in provider.models:
    if m.id == modelId:
      return some(m)
  return none(ModelConfig)
