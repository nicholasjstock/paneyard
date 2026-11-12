require "fileutils"
require "open3"
require "shellwords"

module Orchestrator
  module Runner
    # Getting a project ready to be a workspace on the runner's machine, for
    # the create_workspace tool (Orchestrator::WorkspaceCreation), from
    # whatever already exists, so it ends up a local checkout with a first
    # commit on its default branch and its GitHub repository as origin.
    # Registering it is the orchestrator's, afterwards.
    #
    # check looks at the directory and at GitHub and plans the steps that are
    # missing, finding every problem at once; create carries them out, only
    # when check found none:
    #
    #   nothing at path, nothing on GitHub     create_directory, git_init,
    #                                          first_commit,
    #                                          create_github_repository, push_branch
    #   nothing at path, owner/name on GitHub  clone
    #   a directory that is not git            git_init, first_commit,
    #                                          create_github_repository, push_branch
    #   a repository with no commits           first_commit, (create_github_repository,)
    #                                          push_branch
    #   a repository with no origin            create_github_repository, push_branch
    #   origin lacks the default branch        push_branch
    #   origin has it                          nothing: it is registered as it is
    #
    # The first commit holds a README.md and an AGENTS.md stub (either kept as
    # it is when the directory already has one) and nothing else: other files
    # already there are left untracked for the operator to commit.
    #
    # Each call plans afresh from what exists, so calling create again after a
    # failure carries on from where it stopped. A failure removes only a
    # directory this call made itself, and only while nothing of it is on
    # GitHub; anything that existed before the call is never removed.
    module Projects
      module_function

      BRANCH = "main".freeze
      NAME = /\A[A-Za-z0-9_][A-Za-z0-9._-]{0,99}\z/
      OWNER = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/
      VISIBILITIES = %w[private public internal].freeze
      STUBS = %w[README.md AGENTS.md].freeze

      # Whether `path` can hold new projects: { "path" (expanded), "problems" }.
      def check_projects_dir(path)
        raw = path.to_s.strip
        unless raw.start_with?("/", "~")
          return { "path" => raw, "problems" => [ problem("path_not_absolute", "The projects directory must be an absolute path (or start with ~), not #{raw.inspect}.") ] }
        end

        dir = Pathname(File.expand_path(raw)).cleanpath
        problems = if !dir.directory?
          [ problem("projects_dir_missing", "#{dir} is not a directory here; create it first (mkdir -p #{sh(dir)}).") ]
        elsif !File.writable?(dir)
          [ problem("projects_dir_not_writable", "#{dir} is not writable here.") ]
        else
          []
        end
        { "path" => dir.to_s, "problems" => problems }
      end

      # The plan: { "repository_path", "name", "owner", "github_repository",
      # "visibility", "local" (absent, directory, unborn, repository),
      # "default_base_branch" (nil before a clone), "steps", "notes",
      # "problems" => [{ "code", "message" }] }.
      def check(path:, name:, owner: nil, visibility: nil)
        name = name.to_s.strip
        visibility = (visibility.to_s.strip.presence || "private").downcase
        problems = [ name_problem(name) ]
        problems << problem("visibility_invalid", "visibility must be one of #{VISIBILITIES.join(', ')}, not #{visibility.inspect}.") unless VISIBILITIES.include?(visibility)

        target, local, local_problems = local_state(path)
        plan = plan(target, local)
        plan.merge!("name" => name, "owner" => owner.to_s.strip.presence, "visibility" => visibility)
        problems.concat(local_problems + plan.delete("problems"))

        if local && local_problems.empty? && github_needed?(plan)
          owner, github_problems, exists = check_github(plan["owner"], name, valid_name: NAME.match?(name))
          plan["owner"] = owner
          plan["github_repository"] = "#{owner}/#{name}" if owner.present? && name.present?
          problems.concat(github_problems)
          if exists && local == "absent"
            plan.merge!("steps" => [ "clone" ], "default_base_branch" => nil)
          elsif exists
            problems << github_conflict(target, plan["github_repository"])
          end
        end
        problems << git_identity_problem if plan["steps"].include?("first_commit")
        plan.merge("problems" => problems.compact)
      end

      # Carries out check's plan. Returns it plus "created" (true when the
      # project is ready to register), "done" (the steps carried out),
      # "origin_url", "github_url", and on failure "message"; "remaining" is
      # { "local_repository", "github_repository" }, what exists now.
      def create(path:, name:, owner: nil, visibility: nil, description: nil)
        plan = check(path:, name:, owner:, visibility:)
        if plan["problems"].any?
          return plan.merge("created" => false, "done" => [], "message" => "Nothing was done.", "remaining" => remaining(nil, nil))
        end

        target = Pathname(plan.fetch("repository_path"))
        full_name = plan["github_repository"]
        done = []
        made_directory = false
        current = nil
        plan.fetch("steps").each do |step|
          current = step
          case step
          when "create_directory"
            Sandbox.guard_path!(target, "create a project at")
            Dir.mkdir(target)
            made_directory = true
          when "git_init"
            Worktrees.git!(target, "init", "--quiet", "--initial-branch=#{BRANCH}")
          when "first_commit"
            first_commit!(target, plan.fetch("name"), description)
          when "clone"
            Sandbox.guard_path!(target, "clone a project into")
            ok, message = GitHub.clone_repository(full_name:, target:)
            made_directory = target.exist?
            raise Worktrees::Error, "gh repo clone #{full_name} failed: #{message}" unless ok

            plan["default_base_branch"] = Repositories.detect_default_branch(target)
          when "create_github_repository"
            ok, message = GitHub.create_repository(full_name:, visibility: plan.fetch("visibility"), source: target, description:)
            raise Worktrees::Error, "gh repo create #{full_name} failed: #{message}" unless ok && origin?(target)
          when "push_branch"
            Worktrees.git!(target, "push", "--quiet", "-u", "origin", plan.fetch("default_base_branch"))
          end
          done << step
        end

        plan.merge("created" => true, "done" => done, "origin_url" => (Worktrees.origin_url(target) if origin?(target)),
                   "github_url" => (GitHub.repository_url(full_name) || "https://github.com/#{full_name}" if full_name),
                   "remaining" => remaining(target, full_name))
      rescue Worktrees::Error, Sandbox::Violation, SystemCallError => error
        made_on_github = [ *done, current ].include?("create_github_repository")
        failed(plan, target, full_name, done, made_directory, made_on_github, error.message.strip.chomp("."))
      end

      # --- carrying it out ----------------------------------------------------

      # A README.md and an AGENTS.md stub, written only where missing, as the
      # only files of the commit, on main when the repository has no commit
      # yet whatever its unborn branch was called.
      def first_commit!(target, name, description)
        Worktrees.git!(target, "symbolic-ref", "HEAD", "refs/heads/#{BRANCH}")
        readme = target.join("README.md")
        agents = target.join("AGENTS.md")
        File.write(readme, readme(name, description)) unless readme.exist?
        File.write(agents, agents_stub(name)) unless agents.exist?
        Worktrees.git!(target, "add", "--", *STUBS)
        Worktrees.git!(target, "commit", "--quiet", "-m", "Start #{name}", "--", *STUBS)
      end

      def readme(name, description)
        "# #{name}\n" + (description.present? ? "\n#{description.strip}\n" : "")
      end

      def agents_stub(name)
        <<~MARKDOWN
          # Repository Guidelines

          Instructions for anyone -- AI agent or human -- changing #{name}. It is a new
          project: as its structure, build and test commands, and conventions settle,
          write them down here.

          ## Build, Test, and Development Commands

          None yet.
        MARKDOWN
      end

      # What is left after a failure, and how to go on. Removes the directory
      # only when this call made it and did not get as far as making a GitHub
      # repository from it (one that existed already, cloned, is no reason to
      # keep a half-made clone).
      def failed(plan, target, full_name, done, made_directory, made_on_github, message)
        on_github = made_on_github && full_name.present? && GitHub.repository_exists?(full_name) == true
        if made_directory && !on_github && target&.directory?
          FileUtils.rm_rf(target)
          return plan.merge("created" => false, "done" => [], "remaining" => remaining(nil, nil),
                            "message" => "#{message}. The directory this call made at #{target} was removed again and " \
                              "nothing is left; fix the cause and call create_workspace again.")
        end

        did = done.any? ? "Done before that: #{done.map { |step| step.tr('_', ' ') }.join(', ')}. " : ""
        plan.merge("created" => false, "done" => done,
                   "remaining" => remaining((target if target&.directory?), (full_name if on_github)),
                   "message" => "#{message}. #{did}Nothing was removed. Fix the cause and call create_workspace again with " \
                     "the same arguments: it carries on from here.#{manual_steps(plan, target, full_name, on_github)}")
      end

      def manual_steps(plan, target, full_name, on_github)
        return "" unless on_github && target&.directory?

        steps = []
        steps << "git -C #{sh(target)} remote add origin https://github.com/#{full_name}.git" unless origin?(target)
        steps << "git -C #{sh(target)} push -u origin #{plan['default_base_branch'] || BRANCH}"
        steps << "register_workspace with path #{target}"
        " Or finish by hand: " + steps.each_with_index.map { |step, index| "#{index + 1}. #{step}" }.join(" ")
      end

      def remaining(target, full_name)
        { "local_repository" => target&.to_s, "github_repository" => full_name }
      end

      # --- planning -----------------------------------------------------------

      # [Pathname or nil, local state or nil, problems]
      def local_state(path)
        raw = path.to_s.strip
        return [ nil, nil, [ problem("path_blank", "path is required.") ] ] if raw.empty?
        unless raw.start_with?("/", "~")
          return [ nil, nil, [ problem("path_not_absolute", "path must be an absolute path (or start with ~), not #{raw.inspect}.") ] ]
        end

        target = Pathname(File.expand_path(raw)).cleanpath
        Sandbox.guard_path!(target, "create a project at")
        return [ target, *absent_state(target) ] unless target.exist? || target.symlink?
        return [ target, nil, [ problem("path_not_directory", "#{target} exists and is not a directory.") ] ] unless target.directory?
        return [ target, "directory", [] ] unless Worktrees.git_success?(target, "rev-parse", "--is-inside-work-tree")

        top = Pathname(Worktrees.git!(target, "rev-parse", "--show-toplevel").strip)
        main = Repositories.main_checkout(target)
        if top.realpath != target.realpath || main.realpath != target.realpath
          return [ target, nil, [ problem("inside_checkout", "#{target} is inside, or a worktree of, the checkout #{main}. To use " \
            "that repository, call register_workspace with its path; for a new project, pass a path outside it.") ] ]
        end
        [ target, Worktrees.git_success?(target, "rev-parse", "--verify", "--quiet", "HEAD") ? "repository" : "unborn", [] ]
      rescue Sandbox::Violation => error
        [ target, nil, [ problem("outside_sandbox", error.message) ] ]
      rescue Worktrees::Error => error
        [ target, nil, [ problem("git_error", error.message) ] ]
      end

      def absent_state(target)
        parent = target.parent
        return [ nil, [ problem("parent_missing", "#{parent} does not exist; create it first (mkdir -p #{sh(parent)}) or pass another path.") ] ] unless parent.directory?
        return [ nil, [ problem("parent_not_writable", "#{parent} is not writable here; pass a path somewhere that is.") ] ] unless File.writable?(parent)

        [ "absent", [] ]
      end

      # What is missing locally, before GitHub is asked: { "repository_path",
      # "local", "default_base_branch", "steps", "notes", "problems",
      # "github_repository" }.
      def plan(target, local)
        steps = []
        notes = []
        problems = []
        branch = BRANCH
        case local
        when "absent"
          steps = %w[create_directory git_init first_commit create_github_repository push_branch]
        when "directory"
          steps = %w[git_init first_commit create_github_repository push_branch]
          others = target.children.map { |child| child.basename.to_s } - STUBS
          notes << "#{others.size} file(s) already in #{target} are left untracked: commit what belongs in the repository." if others.any?
        when "unborn"
          steps = [ "first_commit", *("create_github_repository" unless origin?(target)), "push_branch" ]
        when "repository"
          branch = Repositories.detect_default_branch(target)
          if branch.blank?
            problems << problem("no_default_branch", "Could not tell #{target}'s default branch: it has no origin/HEAD, no " \
              "init.defaultBranch, and no main or master branch. Create one, or use register_workspace with defaultBaseBranch.")
          elsif !origin?(target)
            steps = %w[create_github_repository push_branch]
          elsif origin_lacks?(target, branch, notes)
            steps = %w[push_branch]
          end
        end
        { "repository_path" => target&.to_s, "local" => local, "default_base_branch" => (branch if local),
          "github_repository" => nil, "steps" => steps, "notes" => notes, "problems" => problems }
      end

      def github_needed?(plan)
        plan["local"] == "absent" || plan["steps"].include?("create_github_repository")
      end

      # Whether origin is missing the branch, when it can tell. When it cannot
      # (offline, no access) it says so in notes and pushes nothing.
      def origin_lacks?(target, branch, notes)
        _output, error, status = Open3.capture3(GitHub::ENV_OFF_PROMPTS, "git", "-C", target.to_s, "ls-remote", "--exit-code",
                                                "origin", "refs/heads/#{branch}")
        return false if status.success?
        return true if status.exitstatus == 2

        notes << "Could not check whether origin has #{branch} (#{error.strip.lines.first&.strip}), so nothing was pushed."
        false
      end

      def github_conflict(target, full_name)
        problem("github_repository_exists", "GitHub already has #{full_name}, and #{target} is not a clone of it. Choose " \
          "another name; or, if it is the same project, add it as origin yourself (git -C #{sh(target)} remote add origin " \
          "https://github.com/#{full_name}.git, once you know their histories agree) and call create_workspace again.")
      end

      def origin?(target)
        Worktrees.git_success?(target, "remote", "get-url", "origin")
      end

      # --- checking -----------------------------------------------------------

      def name_problem(name)
        return problem("name_blank", "name is required.") if name.empty?
        return if NAME.match?(name) && !name.end_with?(".git")

        problem("name_invalid", "name #{name.inspect} cannot be a GitHub repository and directory name: use up to 100 " \
          "letters, digits, '-', '_' and '.', starting with a letter, digit or '_', e.g. #{name.parameterize.presence&.inspect || '"my-project"'}.")
      end

      # The first commit needs an author.
      def git_identity_problem
        missing = %w[user.name user.email].reject do |key|
          output, _error, status = Open3.capture3("git", "config", "--get", key)
          status.success? && output.strip.present?
        end
        return if missing.empty?

        problem("git_identity_missing", "git has no #{missing.join(' or ')} for the first commit; set it: " +
          missing.map { |key| "git config --global #{key} #{key == 'user.name' ? '"Your Name"' : 'you@example.com'}" }.join("; "))
      end

      # [owner, problems, whether GitHub has owner/name]: everything gh must
      # be able to do for the plan.
      def check_github(owner, name, valid_name:)
        begin
          Sandbox.guard_github!("create or clone a GitHub repository")
        rescue Sandbox::Violation => error
          return [ owner, [ problem("outside_sandbox", error.message) ], false ]
        end
        unless GitHub.installed?
          return [ owner, [ problem("gh_missing", "The GitHub CLI (gh) is not installed here; install it (https://cli.github.com) and log in with gh auth login.") ], false ]
        end
        return [ owner, [ problem("gh_unauthenticated", "gh is not logged in to GitHub here; run gh auth login.") ], false ] unless GitHub.authenticated?

        login = GitHub.login
        owner ||= login
        return [ owner, [ problem("owner_unknown", "Could not tell which GitHub account to use; pass owner.") ], false ] if owner.blank?
        return [ owner, [ problem("owner_invalid", "owner #{owner.inspect} is not a GitHub user or organization name.") ], false ] unless OWNER.match?(owner)

        # A repository that exists is cloned (or conflicts) whoever owns it;
        # only one to be created needs an owner this user may create under.
        exists = valid_name ? GitHub.repository_exists?("#{owner}/#{name}") : false
        return [ owner, [ problem("github_error", "Could not check whether GitHub has #{owner}/#{name}: #{exists.last}") ], false ] if exists.is_a?(Array)
        return [ owner, [], true ] if exists

        [ owner, [ owner_problem(owner, login) ].compact, false ]
      end

      def owner_problem(owner, login)
        type = GitHub.owner_type(owner)
        case type
        when :missing
          problem("owner_missing", "GitHub has no user or organization #{owner.inspect}; check the owner.")
        when Array
          problem("github_error", "Could not look up GitHub owner #{owner.inspect}: #{type.last}")
        when "Organization"
          if GitHub.org_member?(owner) == false
            problem("owner_not_member", "#{login || 'The gh user'} is not a member of the GitHub organization #{owner}, so it " \
              "cannot create repositories there; pass another owner or ask an owner of #{owner} to add you.")
          end
        else
          unless owner.casecmp?(login.to_s)
            problem("owner_not_you", "#{owner} is another GitHub user's account, and gh is logged in as #{login}; " \
              "repositories can only be created under your own account or an organization you belong to.")
          end
        end
      end

      def problem(code, message)
        { "code" => code, "message" => message }
      end

      def sh(value)
        Shellwords.escape(value.to_s)
      end
    end
  end
end
