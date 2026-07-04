---
name: agent_robustness_patterns
description: Guidelines for agents to robustly handle spawned jobs and external processes
metadata:
  type: feedback
model: haiku
---

# Agent Robustness Patterns

## Problem

Agents were launching background jobs (recordings, scripts) without monitoring them, leading to:
- ❌ Jobs hanging silently
- ❌ Agents completing without knowing if actual work succeeded
- ❌ User having to manually detect and kill stuck processes
- ❌ No automatic recovery or retry logic

## Solution: Agent-Side Job Monitoring

Every agent that launches an external job MUST:

### 1. **Monitor Progress** (Not Just Completion)

```typescript
// BAD - Just fire and forget
await runRecording()

// GOOD - Monitor actual progress
const result = await monitoredJob({
  command: "bin/record_demo phone",
  timeout: 300_000,  // 5 minute timeout
  checkInterval: 5000, // Check every 5 seconds
  progressCheck: async () => {
    // Verify output files are actually being created
    return fs.existsSync(expectedVideoPath)
  }
})
```

### 2. **Detect Hangs** (Don't Wait Forever)

```typescript
// Track output file modification time
const lastModified = fs.statSync(videoFile).mtime.getTime()
const now = Date.now()
const staleness = now - lastModified

if (staleness > STALE_THRESHOLD) {
  throw new Error(`Job hung: no output for ${staleness}ms`)
}
```

### 3. **Auto-Recovery** (Kill and Retry)

```typescript
try {
  const result = await monitoredJob({...})
} catch (error) {
  if (error.message.includes('hung')) {
    console.log('Job hung, killing and retrying...')
    killProcess(pid)
    await pause(2000)
    return retryJob() // Try again
  }
}
```

### 4. **Explicit Success/Failure** (Not Just "Process Exited")

```typescript
// Agent should verify actual artifacts exist
const recordingComplete = await verifyJobOutput({
  expectedFiles: [videoPath],
  expectedMinSize: 100_000, // 100KB
  expectedMinDuration: 30, // 30 seconds
})

if (!recordingComplete) {
  throw new Error('Job exited but produced no valid output')
}
```

## Implementation for the orchestrator

The orchestrator (deterministic loop logic, not a separate agent) should:

```typescript
async function launchJobSafely(job) {
  const startTime = Date.now()
  const timeout = job.timeout || 300_000
  
  // 1. Launch process
  const process = spawn(job.command)
  const pid = process.pid
  
  // 2. Monitor progress
  const monitor = setInterval(() => {
    const elapsed = Date.now() - startTime
    
    if (elapsed > timeout) {
      clearInterval(monitor)
      process.kill('SIGTERM')
      throw new Error(`Job timeout after ${elapsed}ms`)
    }
    
    if (job.progressCheck) {
      const hasProgress = job.progressCheck()
      if (!hasProgress) {
        console.warn(`No progress detected in ${job.name}`)
      }
    }
  }, 5000)
  
  // 3. Wait for completion with monitoring
  const result = await new Promise((resolve, reject) => {
    process.on('exit', (code) => {
      clearInterval(monitor)
      
      if (code !== 0) {
        reject(new Error(`${job.name} exited with code ${code}`))
      }
      
      // 4. Verify output exists
      if (job.verifyOutput) {
        const verified = job.verifyOutput()
        if (!verified) {
          reject(new Error(`${job.name} produced no valid output`))
        }
      }
      
      resolve(true)
    })
    
    process.on('error', reject)
  })
  
  return result
}
```

## When Agent Detects Hang

Instead of silently failing:

```
Agent detects: "No new video files in 5 minutes"
  ↓
Agent action: Kill process, log error
  ↓
Agent decision: 
  - Retry? (if first attempt)
  - Fail gracefully? (if retried already)
  - Call @planner for recovery strategy?
  ↓
Agent reports: "Recording hung after 300s, killed process, attempt 2/3"
```

## For @worker (scoped fix tasks)

Agents that apply code fixes should verify:

```typescript
// After applying fix
const syntaxValid = await verifyTypescript()  // frontend scope: typecheck
const syntaxValid = await verifyRails()       // backend scope: rspec
if (!syntaxValid) {
  throw new Error('Applied fix broke compilation/tests')
}

// After re-recording
const videoProduced = fs.existsSync(videoPath) && fs.statSync(videoPath).size > 100_000
if (!videoProduced) {
  throw new Error('Re-recording produced no valid video')
}
```

## For @worker (verification tasks)

Agents analyzing output should verify:

```typescript
// Before trying to analyze
const canAnalyze = await verifyVideoFile(videoPath)
if (!canAnalyze) {
  throw new Error('Video file is corrupted or too small')
}
```

## Key Principles

1. **Agent owns the job** — If agent spawns it, agent monitors it
2. **Progress != Completion** — Job running doesn't mean job succeeding
3. **Explicit verification** — Check artifacts exist, not just "process exited 0"
4. **Automatic recovery** — Detect hang → kill → retry without user intervention
5. **Clear failure reporting** — "Job hung" not "Process exited unexpectedly"

## Example: Robust Recording Job

```typescript
await launchJobSafely({
  name: 'demo-recording',
  command: 'bin/record_demo phone',
  timeout: 300_000,
  
  // Check if new video files are being created
  progressCheck: () => {
    const recentVideos = fs.readdirSync(videoDir)
      .filter(f => f.endsWith('.webm'))
      .map(f => fs.statSync(path.join(videoDir, f)).mtime)
      .sort((a, b) => b - a)
    
    const latest = recentVideos[0]
    const staleness = Date.now() - latest.getTime()
    return staleness < 30_000 // Less than 30s old
  },
  
  // Verify we got a complete recording
  verifyOutput: () => {
    const videos = fs.readdirSync(videoDir).filter(f => f.endsWith('.webm'))
    return videos.some(v => {
      const size = fs.statSync(path.join(videoDir, v)).size
      return size > 100_000 // At least 100KB
    })
  }
})
```

## Why This Matters

Without this:
- ❌ Agents don't know if their work actually succeeded
- ❌ Hangs become user problems, not agent problems
- ❌ No way to distinguish "job failed" from "job just taking a while"

With this:
- ✅ Agents detect and handle their own failures
- ✅ Automatic recovery for transient issues
- ✅ Clear distinction between timeout and success
- ✅ Robust, self-healing autonomous system
