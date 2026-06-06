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
    vendor*: string           ## Explicit vendor adapter name
    thinkingFormat*: string   ## "", "openai", "anthropic", "deepseek", "xiaomi"
    cacheControl*: bool       ## Enable Anthropic prompt caching
    httpProxy*: string        ## Per-provider HTTP proxy URL
    models*: seq[ModelConfig]

  WebSearchSettings* = object
    enabled*: bool
    provider*: string
    providerType*: string     ## "responses" or "messages"

  CompactionSettings* = object
    enabled*: bool
    reserveTokens*: int
    keepRecentTokens*: int

  SandboxSettings* = object
    enabled*: bool
    level*: string            ## "none", "standard", "strict"
    bwrapPath*: string
    allowNetwork*: bool

  MCPHeader* = object
    name*: string
    value*: string

  MCPEnvVar* = object
    name*: string
    value*: string

  MCPServerConfig* = object
    name*: string
    kind*: string             ## "stdio", "http", "sse" (default: stdio)
    command*: string           ## For stdio: absolute path to binary
    args*: seq[string]
    env*: seq[MCPEnvVar]
    url*: string              ## For http/sse: server URL
    headers*: seq[MCPHeader]

  MCPConfig* = object
    servers*: seq[MCPServerConfig]

  ApprovalSettings* = object
    bashWhitelist*: seq[string]  ## Command prefixes that auto-approve in agent mode
    bashBlacklist*: seq[string]  ## Command prefixes that always require approval
    confirmBeforeWrite*: bool    ## Require approval before write/edit tools

  RetrySettings* = object
    enabled*: bool
    maxRetries*: int
    baseDelayMs*: int

  Settings* = ref object
    providers*: Table[string, ProviderConfig]
    defaultProvider*: string
    defaultModel*: string
    defaultMode*: string
    defaultThinkingLevel*: string
    maxContextTokens*: int
    maxOutputTokens*: int
    webSearch*: WebSearchSettings
    compaction*: CompactionSettings
    sandbox*: SandboxSettings
    sessionDir*: string
    skillsDir*: string
    contextFiles*: ContextFilesSettings
    approval*: ApprovalSettings
    retry*: RetrySettings

  ContextFilesSettings* = object
    enabled*: bool
    extraFiles*: seq[string]

proc configDir*(): string =
  let home = getHomeDir()
  result = home / ".nimcode"

proc globalSettingsPath*(): string =
  configDir() / "settings.json"

proc projectSettingsPath*(): string =
  ".nimcode" / "settings.json"

proc globalMCPPath*(): string =
  configDir() / "mcp.json"

proc projectMCPPath*(): string =
  ".nimcode" / "mcp.json"

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
    webSearch: WebSearchSettings(enabled: false, providerType: "responses"),
    compaction: CompactionSettings(enabled: true, reserveTokens: 16384, keepRecentTokens: 20000),
    sandbox: SandboxSettings(enabled: false, level: "none"),
    sessionDir: "",
    skillsDir: "",
    contextFiles: ContextFilesSettings(enabled: true),
    approval: ApprovalSettings(
      bashWhitelist: @["go ", "make ", "git ", "nim ", "nimble "],
      bashBlacklist: @[],
      confirmBeforeWrite: false,
    ),
    retry: RetrySettings(
      enabled: true,
      maxRetries: 3,
      baseDelayMs: 2000,
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
    if provider.vendor != "": providerJson["vendor"] = %provider.vendor
    if provider.thinkingFormat != "": providerJson["thinkingFormat"] = %provider.thinkingFormat
    if provider.cacheControl: providerJson["cacheControl"] = %true
    if provider.httpProxy != "": providerJson["httpProxy"] = %provider.httpProxy
    
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
  
  # Web search
  result["webSearch"] = %*{
    "enabled": settings.webSearch.enabled,
    "provider": settings.webSearch.provider,
    "providerType": settings.webSearch.providerType
  }
  
  # Compaction
  result["compaction"] = %*{
    "enabled": settings.compaction.enabled,
    "reserveTokens": settings.compaction.reserveTokens,
    "keepRecentTokens": settings.compaction.keepRecentTokens
  }
  
  # Sandbox
  result["sandbox"] = %*{
    "enabled": settings.sandbox.enabled,
    "level": settings.sandbox.level,
    "allowNetwork": settings.sandbox.allowNetwork
  }
  
  # Approval settings
  result["approval"] = %*{
    "bashWhitelist": settings.approval.bashWhitelist,
    "bashBlacklist": settings.approval.bashBlacklist,
    "confirmBeforeWrite": settings.approval.confirmBeforeWrite
  }
  
  # Retry settings
  result["retry"] = %*{
    "enabled": settings.retry.enabled,
    "maxRetries": settings.retry.maxRetries,
    "baseDelayMs": settings.retry.baseDelayMs
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
    except CatchableError:
      stderr.writeLine("Warning: could not create project config dir: " & getCurrentExceptionMsg())

proc parseModels(modelsNode: JsonNode): seq[ModelConfig] =
  result = @[]
  for mNode in modelsNode:
    var mc = ModelConfig()
    mc.id = mNode{"id"}.getStr("")
    mc.name = mNode{"name"}.getStr("")
    mc.reasoning = mNode{"reasoning"}.getBool(false)
    mc.contextWindow = mNode{"contextWindow"}.getInt(0)
    mc.maxTokens = mNode{"maxTokens"}.getInt(0)
    result.add(mc)

proc parseProviders(data: JsonNode): Table[string, ProviderConfig] =
  ## Parse providers from JSON data
  result = initTable[string, ProviderConfig]()
  if not data.hasKey("providers"): return
  let providersNode = data["providers"]
  for name, pNode in providersNode:
    var pc = ProviderConfig()
    pc.apiKey = pNode{"apiKey"}.getStr("")
    pc.baseUrl = pNode{"baseUrl"}.getStr("")
    pc.api = pNode{"api"}.getStr("")
    pc.vendor = pNode{"vendor"}.getStr("")
    pc.thinkingFormat = pNode{"thinkingFormat"}.getStr("")
    pc.cacheControl = pNode{"cacheControl"}.getBool(false)
    pc.httpProxy = pNode{"httpProxy"}.getStr("")
    pc.models = @[]
    if pNode.hasKey("models"):
      pc.models = parseModels(pNode["models"])
    result[name] = pc

proc parseMCPHeader(node: JsonNode): MCPHeader =
  result.name = node{"name"}.getStr("")
  result.value = node{"value"}.getStr("")

proc parseMCPEnvVar(node: JsonNode): MCPEnvVar =
  result.name = node{"name"}.getStr("")
  result.value = node{"value"}.getStr("")

proc loadMCPConfig*(path: string): MCPConfig =
  ## Load MCP configuration from a JSON file
  result = MCPConfig()
  if not fileExists(path):
    return
  try:
    let data = parseFile(path)
    if not data.hasKey("mcpServers"): return
    for name, srvNode in data["mcpServers"]:
      var srv = MCPServerConfig()
      srv.name = name
      srv.kind = srvNode{"type"}.getStr("stdio")
      srv.command = srvNode{"command"}.getStr("")
      srv.url = srvNode{"url"}.getStr("")
      if srvNode.hasKey("args"):
        for arg in srvNode["args"]:
          srv.args.add(arg.getStr(""))
      if srvNode.hasKey("env"):
        for envNode in srvNode["env"]:
          srv.env.add(parseMCPEnvVar(envNode))
      if srvNode.hasKey("headers"):
        for hNode in srvNode["headers"]:
          srv.headers.add(parseMCPHeader(hNode))
      result.servers.add(srv)
  except:
    stderr.writeLine("Warning: could not load MCP config from " & path & ": " & getCurrentExceptionMsg())

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
      if data.hasKey("sessionDir"):
        result.sessionDir = data["sessionDir"].getStr()
      if data.hasKey("skillsDir"):
        result.skillsDir = data["skillsDir"].getStr()
      
      # Parse web search
      if data.hasKey("webSearch"):
        let ws = data["webSearch"]
        if ws.hasKey("enabled"): result.webSearch.enabled = ws["enabled"].getBool(false)
        if ws.hasKey("provider"): result.webSearch.provider = ws["provider"].getStr()
        if ws.hasKey("providerType"): result.webSearch.providerType = ws["providerType"].getStr()
      
      # Parse compaction
      if data.hasKey("compaction"):
        let cp = data["compaction"]
        if cp.hasKey("enabled"): result.compaction.enabled = cp["enabled"].getBool(true)
        if cp.hasKey("reserveTokens"): result.compaction.reserveTokens = cp["reserveTokens"].getInt(16384)
        if cp.hasKey("keepRecentTokens"): result.compaction.keepRecentTokens = cp["keepRecentTokens"].getInt(20000)
      
      # Parse sandbox
      if data.hasKey("sandbox"):
        let sb = data["sandbox"]
        if sb.hasKey("enabled"): result.sandbox.enabled = sb["enabled"].getBool(false)
        if sb.hasKey("level"): result.sandbox.level = sb["level"].getStr("none")
        if sb.hasKey("bwrapPath"): result.sandbox.bwrapPath = sb["bwrapPath"].getStr()
        if sb.hasKey("allowNetwork"): result.sandbox.allowNetwork = sb["allowNetwork"].getBool(false)
      
      # Parse context files
      if data.hasKey("contextFiles"):
        let cf = data["contextFiles"]
        if cf.hasKey("enabled"): result.contextFiles.enabled = cf["enabled"].getBool(true)
        if cf.hasKey("extraFiles"):
          result.contextFiles.extraFiles = @[]
          for f in cf["extraFiles"]:
            result.contextFiles.extraFiles.add(f.getStr())
      
      # Parse approval
      if data.hasKey("approval"):
        let a = data["approval"]
        if a.hasKey("bashWhitelist"):
          result.approval.bashWhitelist = @[]
          for v in a["bashWhitelist"]:
            result.approval.bashWhitelist.add(v.getStr())
        if a.hasKey("bashBlacklist"):
          result.approval.bashBlacklist = @[]
          for v in a["bashBlacklist"]:
            result.approval.bashBlacklist.add(v.getStr())
        if a.hasKey("confirmBeforeWrite"):
          result.approval.confirmBeforeWrite = a["confirmBeforeWrite"].getBool(false)
      # Parse retry
      if data.hasKey("retry"):
        let r = data["retry"]
        if r.hasKey("enabled"):
          result.retry.enabled = r["enabled"].getBool(true)
        if r.hasKey("maxRetries"):
          result.retry.maxRetries = r["maxRetries"].getInt(3)
        if r.hasKey("baseDelayMs"):
          result.retry.baseDelayMs = r["baseDelayMs"].getInt(2000)
      # Parse providers
      let parsed = parseProviders(data)
      if parsed.len > 0:
        result.providers = parsed
    except CatchableError:
      stderr.writeLine("Warning: could not load global settings: " & getCurrentExceptionMsg())

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
      if data.hasKey("defaultThinkingLevel"):
        result.defaultThinkingLevel = data["defaultThinkingLevel"].getStr()
      # Project providers merge/override global
      let parsed = parseProviders(data)
      if parsed.len > 0:
        for name, pc in parsed:
          result.providers[name] = pc
    except CatchableError:
      stderr.writeLine("Warning: could not load project settings: " & getCurrentExceptionMsg())

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
