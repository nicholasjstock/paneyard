require "json"
require "open3"

# Turns a take (the lossless recording and its timings.json) into the README
# cut: every beat kept, in order, each sped up just enough to fit its budget,
# with a small "N×" badge while it is sped up. A live agent's minutes of work
# become seconds; the typing and the moments worth reading stay at real speed
# when they fit. Then a 1280-wide MP4 and a palette-optimised GIF of it.
#
# One concat *filter* over trimmed segments, never the concat demuxer: the
# filter works on decoded frames, so there is no segment-boundary timestamp
# arithmetic to get wrong.
module Cut
  # Seconds each beat may take in the cut (docs/demo-recording-plan.md §5).
  BUDGETS = {
    "idle" => 1, "ask" => 8, "spawn" => 3, "work" => 3, "hunk" => 7,
    "merge" => 9, "close" => 4, "confirm" => 7, "end" => 3
  }.freeze
  # Faster than this reads as a glitch rather than a time-lapse.
  MAX_SPEED = 40.0
  WIDTH = 1280
  GIF_WIDTH = 1200
  GIF_FPS = 12
  BADGE_FONT = "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Bold.ttf".freeze

  module_function

  # Returns [mp4, gif] paths.
  def call(video:, timings:, out_dir:, name: "demo")
    beats = JSON.parse(File.read(timings))
    segments = beats.map do |beat, span|
      length = span["end"] - span["start"]
      speed = [ [ length / BUDGETS.fetch(beat, length), 1.0 ].max, MAX_SPEED ].min
      { beat:, start: span["start"], end: span["end"], speed: }
    end

    mp4 = File.join(out_dir, "#{name}.mp4")
    gif = File.join(out_dir, "#{name}.gif")
    ffmpeg("-i", video, "-filter_complex", filter(segments), "-map", "[out]",
           "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4)
    ffmpeg("-i", mp4, "-filter_complex",
           "fps=#{GIF_FPS},scale=#{GIF_WIDTH}:-1:flags=lanczos,split[a][b];" \
           "[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
           gif)
    segments.each { |s| puts format("  %-8s %6.1fs -> %5.1fs (%.1fx)", s[:beat], s[:end] - s[:start], (s[:end] - s[:start]) / s[:speed], s[:speed]) }
    [ mp4, gif ]
  end

  def filter(segments)
    parts = segments.each_with_index.map do |segment, index|
      chain = "[0:v]trim=start=#{segment[:start]}:end=#{segment[:end]},setpts=(PTS-STARTPTS)/#{segment[:speed].round(3)}"
      chain += ",#{badge(segment[:speed])}" if segment[:speed] >= 1.5
      "#{chain},scale=#{WIDTH}:-2:flags=lanczos,fps=30[s#{index}]"
    end
    inputs = segments.each_index.map { "[s#{_1}]" }.join
    "#{parts.join(';')};#{inputs}concat=n=#{segments.size}:v=1:a=0[out]"
  end

  def badge(speed)
    "drawtext=fontfile=#{BADGE_FONT}:text='#{speed.round}×':x=w-tw-36:y=h-th-30:fontsize=44:" \
      "fontcolor=0x1e1e2e:box=1:boxcolor=0x89b4fa@0.95:boxborderw=14"
  end

  def ffmpeg(*args)
    output, status = Open3.capture2e("ffmpeg", "-nostdin", "-y", "-loglevel", "error", *args)
    raise "ffmpeg failed: #{output}" unless status.success?
  end
end
