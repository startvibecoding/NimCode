import std/[os, strutils, sequtils, tables, algorithm]

type
  SkillReference* = object
    path*: string       ## Relative path (e.g. "references/audio.md")
    fullPath*: string   ## Absolute path
    label*: string      ## Display label
    autoLoad*: bool     ## true if marked [已加载], false if [待按需加载]
    loaded*: bool       ## Whether this reference has been loaded
    content*: string    ## Loaded content

  Skill* = object
    name*: string                    ## Skill name (directory name)
    path*: string                    ## Absolute path to SKILL.md
    dir*: string                     ## Skill directory
    description*: string             ## First line or heading description
    content*: string                 ## Full SKILL.md content
    source*: string                  ## "global" or "project"
    references*: seq[SkillReference] ## Parsed references

  Manager* = ref object
    globalDir*: string   ## ~/.nimcode/skills
    projectDir*: string  ## .skills/ in project root
    skills*: Table[string, Skill]

proc newManager*(globalDir, projectDir: string): Manager =
  result = Manager(
    globalDir: globalDir,
    projectDir: projectDir,
    skills: initTable[string, Skill]()
  )

proc loadFromDir(m: Manager, dir: string, source: string) =
  ## Loads all skills from a directory
  if not dirExists(dir):
    return
  
  for kind, entry in walkDir(dir):
    if kind != pcDir:
      continue
    
    let skillDir = entry
    let skillFile = skillDir / "SKILL.md"
    
    if not fileExists(skillFile):
      continue
    
    try:
      let content = readFile(skillFile)
      let name = skillDir.extractFilename
      
      # Get description from first non-empty line
      var description = ""
      for line in content.splitLines():
        let stripped = line.strip
        if stripped != "":
          description = stripped
          break
      
      # Parse references
      var references: seq[SkillReference] = @[]
      for line in content.splitLines():
        if line.contains("[") and line.contains("]"):
          # Simple reference parsing
          let start = line.find("[")
          let stop = line.find("]", start)
          if start >= 0 and stop > start:
            let refPath = line[start+1 ..< stop]
            if refPath.contains(".md"):
              references.add(SkillReference(
                path: refPath,
                fullPath: skillDir / refPath,
                label: refPath,
                autoLoad: false,
                loaded: false
              ))
      
      m.skills[name] = Skill(
        name: name,
        path: skillFile,
        dir: skillDir,
        description: description,
        content: content,
        source: source,
        references: references
      )
    except:
      continue

proc load*(m: Manager) =
  ## Discovers and loads all skills from global and project directories
  ## Project-local skills override global skills with the same name
  
  # Load global skills first (lower priority)
  if m.globalDir != "":
    m.loadFromDir(m.globalDir, "global")
  
  # Load project skills (higher priority, overrides global)
  if m.projectDir != "":
    m.loadFromDir(m.projectDir, "project")

proc list*(m: Manager): seq[Skill] =
  ## Returns all loaded skills
  result = @[]
  for skill in m.skills.values:
    result.add(skill)
  result.sort(proc (a, b: Skill): int = cmp(a.name, b.name))

proc get*(m: Manager, name: string): Skill =
  ## Gets a skill by name
  return m.skills[name]

proc buildAllSkillsContext*(m: Manager): string =
  ## Builds context from all loaded skills
  let skills = m.list()
  if skills.len == 0:
    return ""
  
  result = "\n## Available Skills\n"
  result.add("The following specialized instructions are available for specific tasks:\n")
  
  for skill in skills:
    result.add("\n### " & skill.name & "\n")
    result.add("Description: " & skill.description & "\n")
  
  result.add("\nWhen a task matches a skill's description, read the full skill file for detailed instructions.\n")
  result.add("If a skill file references relative paths, resolve them against the skill directory.\n")
