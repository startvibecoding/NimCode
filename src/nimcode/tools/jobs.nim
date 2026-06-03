import std/[os, osproc, times, strutils, tables, json]

type
  BackgroundJob* = ref object
    id*: int
    command*: string
    pid*: int
    startTime*: DateTime
    done*: bool
    exitCode*: int
    stdout*: string
    stderr*: string
    err*: string
    process: Process

  JobManager* = ref object
    jobs*: Table[int, BackgroundJob]
    nextId*: int

proc newJobManager*(): JobManager =
  result = JobManager(
    jobs: initTable[int, BackgroundJob](),
    nextId: 0
  )

proc addJob*(jm: JobManager, process: Process, command: string): BackgroundJob =
  jm.nextId += 1
  result = BackgroundJob(
    id: jm.nextId,
    command: command,
    pid: process.processID,
    startTime: now(),
    done: false,
    process: process
  )
  jm.jobs[result.id] = result

proc getJob*(jm: JobManager, id: int): BackgroundJob =
  return jm.jobs.getOrDefault(id, nil)

proc listJobs*(jm: JobManager): seq[BackgroundJob] =
  result = @[]
  for job in jm.jobs.values:
    result.add(job)

proc killJob*(jm: JobManager, id: int): bool =
  let job = jm.jobs.getOrDefault(id, nil)
  if job == nil:
    return false
  
  if job.done:
    return false
  
  try:
    job.process.kill()
    job.done = true
    job.exitCode = -1
    return true
  except:
    return false

proc markDone*(job: BackgroundJob, exitCode: int, stdout, stderr: string) =
  job.done = true
  job.exitCode = exitCode
  job.stdout = stdout
  job.stderr = stderr

proc formatJobStatus*(job: BackgroundJob): string =
  let duration = now() - job.startTime
  let durationStr = $duration.inSeconds & "s"
  
  if job.done:
    result = "[" & $job.id & "] " & job.command & "\n"
    result.add("  Status: finished (exit code: " & $job.exitCode & ")\n")
    result.add("  Duration: " & durationStr & "\n")
    if job.stdout.len > 0:
      result.add("  Stdout: " & job.stdout[0 ..< min(200, job.stdout.len)] & "\n")
    if job.stderr.len > 0:
      result.add("  Stderr: " & job.stderr[0 ..< min(200, job.stderr.len)] & "\n")
  else:
    result = "[" & $job.id & "] " & job.command & "\n"
    result.add("  Status: running (PID: " & $job.pid & ")\n")
    result.add("  Duration: " & durationStr & "\n")

proc listJobsToolParams*(): JsonNode =
  %*{
    "type": "object",
    "properties": {}
  }

proc killToolParams*(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "jobId": {"type": "integer", "description": "The job ID to kill"}
    },
    "required": ["jobId"]
  }
