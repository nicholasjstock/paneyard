require "open3"

namespace :sandbox do
  desc "Create the sandbox's scratch git repo and register it as a workspace (PANEYARD_SANDBOX=1 only)"
  task seed: :environment do
    abort "sandbox:seed only runs in a sandbox instance (PANEYARD_SANDBOX=1); see bin/sandbox" unless Orchestrator::Sandbox.enabled?

    name = ENV.fetch("SANDBOX_WORKSPACE", "sandbox-demo")
    project = Pathname(Orchestrator::Sandbox.root).join("repos", name)
    # Any checkout will do (no `main` directory needed); a second branch lets a
    # run be queued from something other than the default.
    checkout = project.join("checkout")
    origin = project.join("origin.git")

    git = lambda do |*args, dir: checkout|
      output, status = Open3.capture2e("git", "-C", dir.to_s, *args)
      abort "git #{args.join(' ')} failed in #{dir}: #{output}" unless status.success?
    end

    unless checkout.join(".git").exist?
      FileUtils.mkdir_p(checkout)
      git.call("init", "--bare", "-b", "main", origin.to_s, dir: project)
      git.call("init", "-b", "main")
      git.call("config", "user.email", "sandbox@example.test")
      git.call("config", "user.name", "Paneyard Sandbox")
      File.write(checkout.join("README.md"), "Scratch repository for a paneyard sandbox.\n")
      git.call("add", "README.md")
      git.call("commit", "-m", "Initial commit")
      git.call("remote", "add", "origin", origin.to_s)
      git.call("push", "-u", "origin", "main")
      git.call("branch", "feature/sandbox")
    end

    workspace = Workspace.find_or_create_by!(name:) do |record|
      record.repository_path = checkout.to_s
      record.default_base_branch = "main"
    end
    puts "#{workspace.name} #{workspace.id} #{workspace.repository_path}"
  end
end

namespace :sandbox do
  # queue_run cannot choose a runner yet, so bin/sandbox verify queues its
  # remote-runner scenario here: the same run queue_run would make, on RUNNER.
  desc "Queue a run on a named runner (PANEYARD_SANDBOX=1 only): WORKSPACE, RUNNER, TASK"
  task queue_on_runner: :environment do
    abort "sandbox:queue_on_runner only runs in a sandbox instance (PANEYARD_SANDBOX=1); see bin/sandbox" unless Orchestrator::Sandbox.enabled?

    workspace = Workspace.find_by!(name: ENV.fetch("WORKSPACE"))
    runner = RegisteredRunner.find_by!(name: ENV.fetch("RUNNER"))
    run = workspace.runs.new(
      run_id: "run-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}", task: ENV.fetch("TASK"),
      base_branch: workspace.default_base_branch, launcher_variant: "claude", target_root: workspace.repository_path_for(runner),
      status: "queued", launched_by: "mcp", runner:
    )
    run.worktree_name = Orchestrator::GitWorktree.name_for(run)
    run.save!
    RunDispatchJob.perform_later
    puts run.run_id
  end
end
