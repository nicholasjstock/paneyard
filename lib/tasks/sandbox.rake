require "open3"

namespace :sandbox do
  desc "Create the sandbox's scratch git repo and register it as a workspace (PANEYARD_SANDBOX=1 only)"
  task seed: :environment do
    abort "sandbox:seed only runs in a sandbox instance (PANEYARD_SANDBOX=1); see bin/sandbox" unless Orchestrator::Sandbox.enabled?

    name = ENV.fetch("SANDBOX_WORKSPACE", "sandbox-demo")
    project = Pathname(Orchestrator::Sandbox.root).join("repos", name)
    main = project.join("main")
    origin = project.join("origin.git")

    git = lambda do |*args, dir: main|
      output, status = Open3.capture2e("git", "-C", dir.to_s, *args)
      abort "git #{args.join(' ')} failed in #{dir}: #{output}" unless status.success?
    end

    unless main.join(".git").exist?
      FileUtils.mkdir_p(main)
      git.call("init", "--bare", "-b", "main", origin.to_s, dir: project)
      git.call("init", "-b", "main")
      git.call("config", "user.email", "sandbox@example.test")
      git.call("config", "user.name", "Paneyard Sandbox")
      File.write(main.join("README.md"), "Scratch repository for a paneyard sandbox.\n")
      git.call("add", "README.md")
      git.call("commit", "-m", "Initial commit")
      git.call("remote", "add", "origin", origin.to_s)
      git.call("push", "-u", "origin", "main")
    end

    workspace = Workspace.find_or_create_by!(name:) { |record| record.root_path = project.to_s }
    puts "#{workspace.name} #{workspace.id} #{workspace.root_path}"
  end
end
