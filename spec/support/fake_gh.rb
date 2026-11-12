require "json"
require "fileutils"

# A stand-in for the GitHub CLI, so no spec ever reaches GitHub: an executable
# Runner::GitHub runs instead of `gh` (tag an example :fake_gh, or call
# use_fake_gh!). It answers the calls Runner::GitHub makes from a JSON state
# file. `repo create` makes a bare repository under the state directory and
# adds it as the source's origin, and `repo clone` clones one, with real git,
# so what the project ends up with is real.
#
# fake_gh.update(...) changes what it answers: "login", "authenticated",
# "owners" ({ name => "User" | "Organization" }), "memberships" (orgs the user
# is in), "repos" (existing owner/name), "create" ("ok", "fail" before making
# anything, or "push_fail": made, but refusing pushes), "clone" ("ok" or
# "fail", leaving a partial directory). fake_gh.seed(owner/name) puts a
# repository with a commit on main "on GitHub". fake_gh.calls is every argv it
# was given.
module FakeGh
  SCRIPT = <<~'RUBY'.freeze
    #!/usr/bin/env -S ruby --disable-gems
    require "json"
    require "fileutils"
    dir = File.dirname(File.expand_path(__FILE__))
    state_path = File.join(dir, "state.json")
    state = JSON.parse(File.read(state_path))
    File.open(File.join(dir, "calls.log"), "a") { |f| f.puts(JSON.generate(ARGV)) }
    save = -> { File.write(state_path, JSON.generate(state)) }
    not_found = ->(path) { warn "gh: Not Found (HTTP 404)\n{\"message\":\"Not Found\"} #{path}"; exit 1 }
    args = ARGV.dup

    case args.shift
    when "--version"
      puts "gh version 2.99.0 (fake)"
    when "auth"
      unless state["authenticated"]
        warn "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        exit 1
      end
      puts "github.com: Logged in to github.com account #{state['login']}"
    when "api"
      path = args.shift
      case path
      when "user" then puts state["login"]
      when %r{\Ausers/(.+)\z}
        type = state.fetch("owners", {})[$1] || ($1 == state["login"] ? "User" : nil)
        type ? puts(type) : not_found.(path)
      when %r{\Auser/memberships/orgs/(.+)\z}
        state.fetch("memberships", []).include?($1) ? puts("active") : not_found.(path)
      when %r{\Arepos/(.+)\z}
        name = $1
        not_found.(path) unless state.fetch("repos", []).include?(name)
        puts "https://github.com/#{name}" unless args.include?("--silent")
      else
        warn "fake gh: unexpected api #{path}"
        exit 2
      end
    when "repo"
      sub = args.shift
      name = args.shift
      bare = File.join(dir, "github", "#{name}.git")
      case sub
      when "create"
        source = args[args.index("--source") + 1]
        if state["create"] == "fail"
          warn "GraphQL: Name already exists on this account (createRepository)"
          exit 1
        end
        FileUtils.mkdir_p(File.dirname(bare))
        system("git", "init", "--quiet", "--bare", "--initial-branch=main", bare, exception: true)
        if state["create"] == "push_fail"
          hook = File.join(bare, "hooks", "pre-receive")
          File.write(hook, "#!/bin/sh\necho 'remote: push refused (fake)' >&2\nexit 1\n")
          File.chmod(0o755, hook)
        end
        state["repos"] = state.fetch("repos", []) + [ name ]
        save.()
        system("git", "-C", source, "remote", "add", "origin", bare, exception: true)
        puts "https://github.com/#{name}"
      when "clone"
        target = args.shift
        not_found.("repos/#{name}") unless state.fetch("repos", []).include?(name)
        if state["clone"] == "fail"
          FileUtils.mkdir_p(target)
          warn "fatal: the remote end hung up unexpectedly"
          exit 1
        end
        system("git", "clone", "--quiet", bare, target, exception: true)
      else
        abort "fake gh: unexpected repo #{sub}"
      end
    else
      warn "fake gh: unexpected #{ARGV.inspect}"
      exit 2
    end
  RUBY

  class Fake
    attr_reader :dir

    def initialize(dir)
      @dir = dir
      FileUtils.mkdir_p(dir)
      File.write(executable, SCRIPT)
      File.chmod(0o755, executable)
      write("login" => "operator", "authenticated" => true, "owners" => {}, "memberships" => [], "repos" => [], "create" => "ok", "clone" => "ok")
    end

    def executable
      File.join(dir, "gh")
    end

    def state
      JSON.parse(File.read(File.join(dir, "state.json")))
    end

    def update(changes)
      write(state.merge(changes))
    end

    def calls
      path = File.join(dir, "calls.log")
      File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
    end

    # A repository already on GitHub, with one commit on `branch`.
    def seed(full_name, branch: "main")
      bare = remote(full_name)
      work = File.join(dir, "seed-work")
      run!("git", "init", "--quiet", "--bare", "--initial-branch=#{branch}", bare)
      run!("git", "clone", "--quiet", bare, work)
      File.write(File.join(work, "README.md"), "# #{full_name}\n")
      run!("git", "-C", work, "add", ".")
      run!("git", "-C", work, "-c", "user.name=Seed", "-c", "user.email=seed@example.test", "commit", "--quiet", "-m", "seed")
      run!("git", "-C", work, "push", "--quiet", "origin", branch)
      FileUtils.rm_rf(work)
      update("repos" => state.fetch("repos") + [ full_name ])
    end

    # The bare repository standing in for owner/name on GitHub.
    def remote(full_name)
      File.join(dir, "github", "#{full_name}.git")
    end

    private

    def run!(*command)
      system(*command, exception: true, out: File::NULL, err: File::NULL)
    end

    def write(state)
      File.write(File.join(dir, "state.json"), JSON.generate(state))
    end
  end

  def use_fake_gh!(dir)
    fake = Fake.new(dir)
    allow(Orchestrator::Runner::GitHub).to receive(:executable).and_return(fake.executable)
    fake
  end
end

RSpec.configure do |config|
  config.include FakeGh
end

# No spec reaches the real gh by accident: one that forgot use_fake_gh! finds
# no gh installed.
RSpec.configure do |config|
  config.before do
    allow(Orchestrator::Runner::GitHub).to receive(:executable).and_return("/nonexistent/paneyard-spec/gh")
  end
end
