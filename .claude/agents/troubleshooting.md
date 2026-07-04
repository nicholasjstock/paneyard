# Demo Recording & Verification Troubleshooting

Quick reference for common issues and their fixes.

## Recording Issues

### ❌ esbuild Transform Error
```
Error: Unexpected "}" at line XXXX
```

**Cause:** Mismatched braces in `front/scripts/record-demo.ts`

**Fix:**
```bash
# Check syntax
node -e "
const fs = require('fs');
const code = fs.readFileSync('front/scripts/record-demo.ts', 'utf8');
const lines = code.split('\\n');
let braces = 0;
for (let i = 0; i < lines.length; i++) {
  for (const char of lines[i]) {
    if (char === '{') braces++;
    if (char === '}') braces--;
  }
  if (braces < 0) {
    console.log(\`Line \${i+1}: extra closing brace\`);
    break;
  }
}
"

# Look for extra } or missing {
# Common: extra closing brace after if/else block
```

**Prevention:** Run brace-check after editing record-demo.ts

---

### ❌ dockPage.locator is not a function

**Cause:** Wrong type passed to helper function

**Current state:** Fixed in recent version - all helpers now accept `WindowTarget` objects

**Check:**
```typescript
// ✅ Correct
await waitForDockBadge(dockTarget, 'Sarah')  // dockTarget is WindowTarget

// ❌ Wrong (don't do this)
await waitForDockBadge(dockTarget.page, 'Sarah')  // passing Page instead
```

---

### ❌ Recording exits with no video output

**Cause:** Runtime error during recording, video files never created

**Debug:**
```bash
# Check last 50 lines of log
tail -50 /tmp/record_demo.log

# Look for error messages like:
# - TypeError
# - Cannot find element
# - Timeout waiting for...
```

**Common causes:**
1. **Element not found** — UI element selector changed or isn't visible
2. **Timeout** — Page loads too slowly or WebSocket message never arrives
3. **Navigation failure** — Link URL is invalid

---

## Verification Issues

### ❌ Frame extraction fails
```bash
ffmpeg: invalid syntax
```

**Fix:** Quote filenames and paths
```bash
ffmpeg -ss 15 -i "demo-output/video.mp4" -vframes 1 "frame-15s.png"
```

---

### ❌ Video shows nothing / black screen

**Cause:** Xvfb/ffmpeg configuration issue in Docker

**Check:**
```bash
# Verify video has content
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 video.mp4

# If duration=0 or very low, recording had no frames
# Check Docker logs for Xvfb startup failures
```

---

### ❌ Phone window always shows "Waiting…"

**Cause:** WebSocket broadcast not received or not subscribed

**Check flow:**
1. Dock clicks badge → triggers POST `/demo_select_worker`
2. Backend receives POST → broadcasts on `test_demo_selection` stream
3. Phone window subscribes to `TestDemoSelectionChannel`
4. Phone receives broadcast → updates state → shows message thread

**Debug steps:**
- [ ] Check `/demo_select_worker` endpoint returns 200
- [ ] Verify `TestDemoSelectionChannel` broadcast happens
- [ ] Check phone window `useTestDemoSelectionWebSocket()` is subscribed
- [ ] Verify no WebSocket connection errors in console

---

### ❌ Dock never shows badges

**Cause:** Messages not sent to `TestNotificationsChannel`

**Check:**
- [ ] `/demo_users` API returns workers
- [ ] Backend sends messages to correct channel
- [ ] Dock window `useTestNotificationsWebSocket()` is listening
- [ ] Badge CSS/elements exist

---

### ❌ CTA link not clickable

**Cause:** Link not rendered or not in expected location

**Check frames:**
```bash
# Extract frame where message should appear
ffmpeg -ss 40 -i video.mp4 -vframes 1 frame-40s.png

# Open and inspect:
# - Is worker name visible?
# - Are message bubbles visible?
# - Is there a blue underlined link?
```

---

## Docker-Specific Issues

### ❌ Docker build fails
```
failed to solve with frontend dockerfile.v0
```

**Fix:**
```bash
docker system prune -a --volumes  # Clean everything
bin/record_demo phone --docker     # Rebuild from scratch
```

---

### ❌ Xvfb timeout in Docker
```
Xvfb didn't start before timeout
```

**Cause:** Slow machine or Docker resource limits

**Fix in docker/record-demo/run-in-xvfb.sh:**
```bash
# Increase sleep
sleep 3  # from sleep 1
```

---

## Success Criteria

### Recording ✅
- [ ] No esbuild errors
- [ ] Video file exists and is >100KB
- [ ] Duration is 200+ seconds (for full demo)
- [ ] ffprobe shows valid codec (H.264/VP8)

### Verification ✅
- [ ] Frames extract without errors
- [ ] Phone shows state transitions:
  - Idle → (badge click) → Thread → (CTA click) → App page
- [ ] No stuck or frozen frames
- [ ] Timing matches expected (badge by 30s, thread by 60s, nav by 120s)

---

## Quick Commands

```bash
# Record locally (faster for iteration)
bin/record_demo phone

# Record in Docker (better video quality)
bin/record_demo phone --docker

# Check video validity
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height \
  -of default=noprint_wrappers=1 video.mp4

# Extract frame at 30 seconds
ffmpeg -ss 30 -i video.mp4 -vframes 1 -q:v 2 frame.png

# List all videos in demo-output
ls -lh demo-output/*.mp4 demo-output/*.webm 2>/dev/null | sort -k6

# Get latest recording
ls -t demo-output/demo-xvfb-*-phone.mp4 | head -1
```

---

## When to Use Each Agent

| Situation | Use Agent | Command |
|-----------|-----------|---------|
| Need fresh demo video | @worker | `run docker recording` |
| Check if video is valid | @worker | `verify latest recording` |
| Diagnose "why didn't X happen" | @worker | `extract frames and analyze` |
| Fix code issue → test quickly | @worker | `run local recording` |
| Full workflow check | @worker (multiple instances) | Record → Verify → Iterate |
