## Cron/scheduler module for NimCode.
## Supports one-shot and periodic scheduled tasks.
## Includes a background scheduler that checks for due jobs.

import std/[json, os, times, strutils, algorithm, random, osproc, streams, threadpool]

type
  CronJob* = object
    id*: string
    name*: string
    prompt*: string
    schedule*: string       ## @daily, @weekly, @hourly, @every 30m, or empty for one-shot
    oneShot*: bool
    mode*: string           ## "agent" or "yolo"
    enabled*: bool
    createdAt*: Time
    lastRun*: Time
    nextRun*: Time
    runCount*: int
    lastStatus*: string     ## "success", "failed", "running"
    lastError*: string

  CronStore* = ref object
    path: string
    jobs: seq[CronJob]

proc newCronStore*(path: string): CronStore =
  result = CronStore(path: path, jobs: @[])
  # Load existing jobs
  if fileExists(path):
    try:
      let data = parseFile(path)
      if data.kind == JArray:
        for j in data:
          var job = CronJob()
          job.id = j{"id"}.getStr("")
          job.name = j{"name"}.getStr("")
          job.prompt = j{"prompt"}.getStr("")
          job.schedule = j{"schedule"}.getStr("")
          job.oneShot = j{"oneShot"}.getBool(false)
          job.mode = j{"mode"}.getStr("yolo")
          job.enabled = j{"enabled"}.getBool(true)
          job.runCount = j{"runCount"}.getInt(0)
          job.lastStatus = j{"lastStatus"}.getStr("")
          job.lastError = j{"lastError"}.getStr("")
          result.jobs.add(job)
    except:
      discard

proc save(store: CronStore) =
  ## Persist jobs to disk
  var arr = newJArray()
  for job in store.jobs:
    arr.add(%*{
      "id": job.id,
      "name": job.name,
      "prompt": job.prompt,
      "schedule": job.schedule,
      "oneShot": job.oneShot,
      "mode": job.mode,
      "enabled": job.enabled,
      "runCount": job.runCount,
      "lastStatus": job.lastStatus,
      "lastError": job.lastError,
    })
  try:
    createDir(store.path.parentDir())
    writeFile(store.path, arr.pretty())
  except:
    discard

proc generateId(): string =
  ## Generate a short random ID
  let now = getTime().toUnix()
  result = "cron-" & $now & "-" & $(rand(9999))

proc list*(store: CronStore): seq[CronJob] =
  store.jobs

proc get*(store: CronStore, id: string): CronJob =
  for job in store.jobs:
    if job.id == id:
      return job
  raise newException(CatchableError, "Cron job not found: " & id)

proc create*(store: CronStore, name, prompt, schedule: string, oneShot: bool, mode: string): CronJob =
  ## Create a new cron job
  if name == "":
    raise newException(CatchableError, "name is required")
  if prompt == "":
    raise newException(CatchableError, "prompt is required")
  
  let actualMode = if mode == "": "yolo" else: mode
  
  result = CronJob(
    id: generateId(),
    name: name,
    prompt: prompt,
    schedule: schedule,
    oneShot: oneShot,
    mode: actualMode,
    enabled: true,
    createdAt: getTime(),
  )
  store.jobs.add(result)
  store.save()

proc setEnabled*(store: CronStore, id: string, enabled: bool) =
  for i in 0 ..< store.jobs.len:
    if store.jobs[i].id == id:
      store.jobs[i].enabled = enabled
      store.save()
      return
  raise newException(CatchableError, "Cron job not found: " & id)

proc remove*(store: CronStore, id: string) =
  for i in 0 ..< store.jobs.len:
    if store.jobs[i].id == id:
      store.jobs.delete(i)
      store.save()
      return
  raise newException(CatchableError, "Cron job not found: " & id)

proc markRun*(store: CronStore, id: string, status: string, error: string = "") =
  for i in 0 ..< store.jobs.len:
    if store.jobs[i].id == id:
      store.jobs[i].lastRun = getTime()
      store.jobs[i].runCount += 1
      store.jobs[i].lastStatus = status
      store.jobs[i].lastError = error
      store.save()
      return

proc formatSchedule*(schedule: string, oneShot: bool): string =
  if oneShot or schedule == "":
    return "(one-shot)"
  return schedule

proc truncate(s: string, maxLen: int): string =
  if s.len <= maxLen:
    return s
  return s[0 ..< maxLen - 3] & "..."

proc formatJob*(job: CronJob): string =
  var sb = ""
  let status = if not job.enabled: "⏸ disabled"
    elif job.lastStatus == "failed": "❌ failed"
    elif job.lastStatus == "running": "🔄 running"
    else: "✅ enabled"
  
  sb &= "- [" & job.id & "] " & job.name & "\n"
  sb &= "  Status: " & status & " | Mode: " & job.mode & " | Schedule: " & formatSchedule(job.schedule, job.oneShot) & " | Runs: " & $job.runCount & "\n"
  sb &= "  Prompt: " & truncate(job.prompt, 80) & "\n"
  let zeroTime: Time = fromUnix(0)
  if job.lastRun != zeroTime:
    sb &= "  Last run: " & job.lastRun.format("yyyy-MM-dd HH:mm:ss") & "\n"
  if job.lastError != "":
    sb &= "  Error: " & job.lastError & "\n"
  return sb

proc formatJobs*(store: CronStore): string =
  let jobs = store.list()
  if jobs.len == 0:
    return "No cron jobs configured."
  result = "Cron jobs (" & $jobs.len & "):\n\n"
  for job in jobs:
    result &= formatJob(job) & "\n"

# ---- Background Scheduler ----

type
  CronScheduler* = ref object
    store*: CronStore
    nimcodeBin*: string      ## Path to nimcode binary for spawning agents
    interval*: int           ## Check interval in seconds (default: 30)
    running*: bool
    workDir*: string

proc newCronScheduler*(store: CronStore, nimcodeBin: string = "", interval: int = 30, workDir: string = ""): CronScheduler =
  let bin = if nimcodeBin != "": nimcodeBin else: "nimcode"
  let dir = if workDir != "": workDir else: getCurrentDir()
  result = CronScheduler(
    store: store,
    nimcodeBin: bin,
    interval: interval,
    running: false,
    workDir: dir,
  )

proc parseScheduleNext*(schedule: string, fromTime: Time): Time =
  ## Parse schedule and return next run time
  let lower = schedule.strip.toLower
  if lower == "@daily" or lower == "@day":
    return fromTime + initDuration(hours = 24)
  elif lower == "@hourly" or lower == "@hour":
    return fromTime + initDuration(hours = 1)
  elif lower == "@weekly" or lower == "@week":
    return fromTime + initDuration(days = 7)
  elif lower.startsWith("@every "):
    let durationStr = lower[7 .. ^1].strip
    var seconds = 0
    if durationStr.endsWith("m"):
      seconds = parseInt(durationStr[0 .. ^2]) * 60
    elif durationStr.endsWith("h"):
      seconds = parseInt(durationStr[0 .. ^2]) * 3600
    elif durationStr.endsWith("s"):
      seconds = parseInt(durationStr[0 .. ^2])
    else:
      seconds = parseInt(durationStr)
    if seconds > 0:
      return fromTime + initDuration(seconds = seconds)
  # Default: 1 hour
  return fromTime + initDuration(hours = 1)

proc isDue(job: CronJob, now: Time): bool =
  ## Check if a job is due to run
  if not job.enabled:
    return false
  if job.lastStatus == "running":
    return false
  # If never run, run now
  let zeroTime: Time = fromUnix(0)
  if job.lastRun == zeroTime:
    return true
  # If next run is set and has passed
  if job.nextRun != zeroTime and now > job.nextRun:
    return true
  return false

proc executeCronJob(scheduler: CronScheduler, job: CronJob) =
  ## Execute a cron job by spawning a nimcode agent
  stderr.writeLine("Cron: Running job '" & job.name & "' (" & job.id & ")")
  scheduler.store.markRun(job.id, "running")
  
  try:
    let modeFlag = if job.mode == "yolo": "-M yolo" else: "-M agent"
    let cmd = scheduler.nimcodeBin & " " & modeFlag & " -P \"" & job.prompt & "\""
    let (output, exitCode) = execCmdEx(cmd, workingDir = scheduler.workDir)
    
    if exitCode == 0:
      scheduler.store.markRun(job.id, "success")
      stderr.writeLine("Cron: Job '" & job.name & "' completed successfully")
    else:
      scheduler.store.markRun(job.id, "failed", "Exit code: " & $exitCode & ": " & output[0 ..< min(output.len, 200)])
      stderr.writeLine("Cron: Job '" & job.name & "' failed (exit " & $exitCode & ")")
  except CatchableError as e:
    scheduler.store.markRun(job.id, "failed", e.msg)
    stderr.writeLine("Cron: Job '" & job.name & "' error: " & e.msg)
  
  # Update next run time
  let jobList = scheduler.store.list()
  for j in jobList:
    if j.id == job.id:
      if j.oneShot:
        scheduler.store.setEnabled(j.id, false)
      else:
        let nextRun = parseScheduleNext(j.schedule, getTime())
        # Update nextRun in store
        for idx in 0 ..< scheduler.store.jobs.len:
          if scheduler.store.jobs[idx].id == j.id:
            scheduler.store.jobs[idx].nextRun = nextRun
            break
        scheduler.store.save()
      break

proc schedulerLoop(scheduler: CronScheduler) =
  ## Main scheduler loop - runs in background thread
  while scheduler.running:
    let now = getTime()
    let jobs = scheduler.store.list()
    
    for job in jobs:
      if isDue(job, now):
        scheduler.executeCronJob(job)
    
    sleep(scheduler.interval * 1000)

proc start*(scheduler: CronScheduler) =
  ## Start the background scheduler
  if scheduler.running:
    return
  scheduler.running = true
  stderr.writeLine("Cron: Scheduler started (interval: " & $scheduler.interval & "s)")
  spawn schedulerLoop(scheduler)

proc stop*(scheduler: CronScheduler) =
  ## Stop the background scheduler
  scheduler.running = false
  stderr.writeLine("Cron: Scheduler stopped")

proc isRunning*(scheduler: CronScheduler): bool =
  scheduler.running
