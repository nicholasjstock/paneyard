require "open3"
require "rubygems/package"
require "securerandom"
require "stringio"
require "timeout"
require "tmpdir"

module Orchestrator
  module Runner
    # Moving a run's work from one runner's machine to another's
    # (Orchestrator::RunMove): this runner's half, as plain data the
    # orchestrator relays, so runners never reach each other.
    #
    #   export  on the machine it leaves: the branch's commits as a git
    #           bundle, the worktree's uncommitted state as two binary diffs
    #           (staged, unstaged) and a tar of its untracked, non-ignored
    #           files, a fingerprint of all that, and the run's saved CLI
    #           transcripts.
    #   import  on the machine it goes to: the bundle fetched into a local
    #           branch of the same name, the run's worktree provisioned on it,
    #           the diffs and files applied, and the result checked against
    #           the fingerprint.
    #
    # Nothing here commits or pushes. The bundle carries only commits the
    # session already made; the uncommitted state crosses as diffs and files
    # and lands uncommitted (staged changes staged again). Toward origin it is
    # read-only: known_commits may fetch from it, nothing else talks to it.
    #
    # The fingerprint is three object ids: HEAD, the tree of the index, and
    # the tree of the whole working state (tracked and untracked, ignored
    # files left out), written with a scratch index. Equal ids mean equal
    # content and modes on both machines, whatever the paths.
    #
    # Errors leave as Runner::Error (RunTransfer::Error).
    module RunTransfer
      class Error < Runner::Error; end
      module_function

      FETCH_TIMEOUT = 120

      # Which of `commits` the repository has, fetching from origin first
      # when any is missing (read-only toward origin; a sandbox fetches only
      # from an origin inside its root). Returns { "have" => [shas],
      # "fetched" => true | false, "fetch_error" => message or nil }.
      def known_commits(repository_path:, commits:)
        repository = repository!(repository_path)
        commits = Array(commits).map(&:to_s).select { |sha| sha.match?(/\A\h{7,64}\z/) }.uniq
        missing = commits.reject { |sha| commit?(repository, sha) }
        fetched = false
        fetch_error = nil
        if missing.any? && origin?(repository)
          begin
            fetch_origin!(repository)
            fetched = true
          rescue Runner::Error => error
            fetch_error = error.message
          end
        end
        { "have" => commits.select { |sha| commit?(repository, sha) }, "fetched" => fetched, "fetch_error" => fetch_error }
      end

      # The run's work on this machine, ready to cross. `path` is the run's
      # worktree, which may be gone (its work was saved, so the janitor
      # removed it): then only the branch crosses. `exclude` is commits the
      # destination already has (known_commits), left out of the bundle;
      # with none the bundle carries the branch's whole history.
      #
      # Returns { "branch", "head", "bundle" (binary, or nil when the
      # destination already has everything), "prerequisites" (the excluded
      # commits it needs), "worktree" (nil without one, else { "staged",
      # "unstaged" (binary diffs), "untracked" (a tar), "files" (the untracked
      # paths), "changed" (the tracked ones), "fingerprint" }) }.
      def export(repository_path:, branch:, path: nil, exclude: [])
        repository = repository!(repository_path)
        raise Error, "#{branch.inspect} is not a valid branch name" unless GitRef.branch?(branch)
        raise Error, "There is no branch `#{branch}` in #{repository}" unless commit?(repository, "refs/heads/#{branch}")

        head = git!(repository, "rev-parse", "refs/heads/#{branch}").strip
        worktree = path.present? && Worktrees.registered?(repository_path: repository, path:) ? Pathname(path) : nil
        check_worktree_branch!(worktree, branch:, head:) if worktree
        {
          "branch" => branch, "head" => head, **bundle(repository, branch:, head:, exclude:),
          "worktree" => worktree && export_worktree(worktree)
        }
      end

      def bundle(repository, branch:, head:, exclude:)
        prerequisites = Array(exclude).map(&:to_s).select { |sha| sha.match?(/\A\h{7,64}\z/) && commit?(repository, sha) }.uniq
        return { "bundle" => nil, "prerequisites" => prerequisites } if prerequisites.any? { |sha| ancestor?(repository, head, sha) }

        Dir.mktmpdir("paneyard-bundle") do |dir|
          file = File.join(dir, "run.bundle")
          git!(repository, "bundle", "create", "--quiet", file, "refs/heads/#{branch}", *prerequisites.map { |sha| "^#{sha}" })
          { "bundle" => File.binread(file), "prerequisites" => prerequisites }
        end
      end

      def check_worktree_branch!(path, branch:, head:)
        current = capture(path, "symbolic-ref", "--quiet", "HEAD").first.strip
        return if current == "refs/heads/#{branch}" && git!(path, "rev-parse", "HEAD").strip == head

        raise Error, "The worktree #{path} is not on branch `#{branch}` (it has #{current.presence || 'a detached HEAD'}); " \
          "check the branch out again there before moving the run"
      end

      def export_worktree(path)
        files = untracked(path)
        {
          "staged" => binary(git!(path, *DIFF, "--cached", "HEAD")),
          "unstaged" => binary(git!(path, *DIFF)),
          "untracked" => binary(tar(path, files)),
          "files" => files.map { |file| text(file) },
          "changed" => git!(path, "diff", "--name-only", "-z", "HEAD").split("\0").map { |file| text(file) },
          "fingerprint" => fingerprint(path)
        }
      rescue Runner::Error, SystemCallError => error
        raise Error, "Could not export the uncommitted state of #{path}: #{error.message}"
      end

      # Diffs that `git apply` takes back whatever the user's diff config.
      DIFF = [ "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false",
        "diff", "--binary", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/" ].freeze

      # Makes the run's worktree here from what export produced: fetches the
      # bundle into the local branch `branch` (creating it, or fast-forwarding
      # it; a branch here with commits the run does not have is diverging, and
      # refused), provisions the worktree on it (Worktrees.provision!; a clean
      # worktree already on the branch here -- one this run left behind when
      # it moved away -- is reused), applies the uncommitted state and checks
      # it against the fingerprint.
      #
      # `replaceable` ([{ "path", "fingerprint" }]) is worktrees here this run
      # left behind when it moved away, with the fingerprint they had when
      # they were exported. One still on the branch, and still exactly as it
      # was then, holds nothing that did not go with the run, so it is reset
      # and reused for the run coming back; one changed since is refused.
      #
      # On any failure nothing it made is left behind: a worktree it created
      # (a copy of work that is still on the source machine) is removed, a
      # branch it created is deleted. Returns provision_worktree's hash plus
      # "head", "branch_created", "fingerprint".
      def import(repository_path:, branch:, base_branch:, label:, head:, bundle: nil, worktree: nil, replaceable: [])
        repository = repository!(repository_path)
        raise Error, "#{branch.inspect} is not a valid branch name" unless GitRef.branch?(branch)

        temp_ref = "refs/paneyard-move/#{SecureRandom.hex(8)}"
        branch_created = false
        provisioned = nil
        begin
          fetch_bundle!(repository, bundle, branch:, temp_ref:) if bundle.present?
          raise Error, "#{repository} does not have the run's commit #{head} and no bundle carried it" unless commit?(repository, head)

          reuse = prepare_branch!(repository, branch:, head:, replaceable:)
          branch_created = reuse == :created
          reuse = nil unless reuse.is_a?(String)
          provisioned = Worktrees.provision!(repository_path: repository, branch:, base_branch:, label:, current_target_root: reuse)
          target = Pathname(provisioned.fetch("target_root"))
          actual = git!(target, "rev-parse", "HEAD").strip
          raise Error, "The new worktree #{target} is at #{actual}, not the run's #{head}" unless actual == head

          fingerprint = worktree.present? ? apply!(target, worktree) : fingerprint(target)
          provisioned.merge("head" => head, "branch_created" => branch_created, "fingerprint" => fingerprint)
        rescue Runner::Error, Herdr::Error, SystemCallError, Gem::Package::Error => error
          problems = roll_back(repository, provisioned, branch:, branch_created:)
          message = error.message
          message += " (and undoing the import: #{problems.join('; ')})" if problems.any?
          raise Error, message
        ensure
          git_success?(repository, "update-ref", "-d", temp_ref)
        end
      rescue Sandbox::Violation => error
        raise Error, error.message
      end

      def fetch_bundle!(repository, bundle, branch:, temp_ref:)
        Dir.mktmpdir("paneyard-bundle") do |dir|
          file = File.join(dir, "run.bundle")
          File.binwrite(file, bundle)
          _output, error, status = capture(repository, "bundle", "verify", "--quiet", file)
          unless status.success?
            raise Error, "#{repository} cannot take the run's commits: #{error.strip} (fetch its base branch from origin there, " \
              "or push the base branch so it can)"
          end

          git!(repository, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", file, "+refs/heads/#{branch}:#{temp_ref}")
        end
      end

      # Gets refs/heads/<branch> to `head` without losing anything. Returns
      # :created, :present (already there, or fast-forwarded, checked out
      # nowhere), or the path of a clean linked worktree that has the branch
      # checked out, fast-forwarded, for provisioning to reuse.
      def prepare_branch!(repository, branch:, head:, replaceable: [])
        checked_out = branch_checkouts(repository, branch)
        unless commit?(repository, "refs/heads/#{branch}")
          git!(repository, "branch", "--no-track", branch, head)
          return :created
        end

        tip = git!(repository, "rev-parse", "refs/heads/#{branch}").strip
        unless tip == head || ancestor?(repository, tip, head)
          raise Error, "Branch `#{branch}` already exists in #{repository} with commits the run does not have (at #{tip.first(12)}); " \
            "it has diverged, so the run cannot move there. Rename or remove that branch there first"
        end
        return update_branch!(repository, branch, tip:, head:) if checked_out.empty?

        main, *linked = git_worktree_entries(repository)
        path = checked_out.first
        if Worktrees.same_path?(path, main.fetch("path")) || !linked.any? { |entry| Worktrees.same_path?(entry.fetch("path"), path) }
          raise Error, "Branch `#{branch}` is checked out in #{path} on this machine; switch that checkout to another branch first"
        end
        if git!(Pathname(path), "status", "--porcelain").present?
          left = Array(replaceable).find { |entry| Worktrees.same_path?(entry["path"].to_s, path) }
          unless left && left["fingerprint"].present? && fingerprint(Pathname(path)) == left["fingerprint"]
            raise Error, "Branch `#{branch}` is checked out in #{path} here, with uncommitted changes that did not go " \
              "with the run when it moved away (or were changed since); deal with them, or remove that worktree, " \
              "before moving the run here"
          end

          # Exactly what was carried away, and is coming back now in its
          # newer state: nothing here is only here.
          git!(Pathname(path), "reset", "--quiet", "--hard", "HEAD")
          git!(Pathname(path), "clean", "--quiet", "-d", "--force")
        end

        git!(Pathname(path), "merge", "--quiet", "--ff-only", head) unless tip == head
        path
      end

      def update_branch!(repository, branch, tip:, head:)
        git!(repository, "update-ref", "refs/heads/#{branch}", head, tip) unless tip == head
        :present
      end

      def branch_checkouts(repository, branch)
        git_worktree_entries(repository).select { |entry| entry["branch"] == "refs/heads/#{branch}" }.map { |entry| entry.fetch("path") }
      end

      def git_worktree_entries(repository)
        git!(repository, "worktree", "list", "--porcelain").split("\n\n").map do |block|
          block.lines.to_h { |line| line.chomp.split(" ", 2) }.then { |fields| { "path" => fields["worktree"], "branch" => fields["branch"] } }
        end
      end

      def apply!(target, worktree)
        unless git!(target, "status", "--porcelain").strip.empty?
          raise Error, "The worktree #{target} already has uncommitted changes, so the run's could not be applied there"
        end

        staged = worktree["staged"].to_s
        unstaged = worktree["unstaged"].to_s
        git!(target, "apply", "--index", "--binary", "--whitespace=nowarn", stdin: staged) if staged.present?
        git!(target, "apply", "--binary", "--whitespace=nowarn", stdin: unstaged) if unstaged.present?
        untar!(target, worktree["untracked"].to_s) if worktree["untracked"].present?

        expected = worktree.fetch("fingerprint")
        actual = fingerprint(target)
        unless actual == expected
          differ = expected.keys.reject { |key| expected[key] == actual[key] }
          raise Error, "The moved worktree does not match the one it came from (#{differ.join(', ')} differ: " \
            "#{differ.map { |key| "#{expected[key].to_s.first(12)} there, #{actual[key].to_s.first(12)} here" }.join('; ')})"
        end
        actual
      end

      def roll_back(repository, provisioned, branch:, branch_created:)
        problems = []
        if provisioned && !provisioned["reused"]
          begin
            Worktrees.remove(repository_path: repository, path: provisioned.fetch("target_root"), force: true)
          rescue Runner::Error => error
            problems << "could not remove the worktree it made, #{provisioned['target_root']}: #{error.message}"
          end
        elsif provisioned
          begin
            Herdr.workspace_close(provisioned.fetch("workspace_id"))
          rescue Herdr::Error
            nil
          end
          problems << "the worktree #{provisioned['target_root']} it reused may hold part of the run's uncommitted changes"
        end
        if branch_created && problems.empty?
          _output, error, status = capture(repository, "branch", "-D", branch)
          problems << "could not delete the branch it made, `#{branch}`: #{error.strip}" unless status.success?
        end
        problems
      end

      # HEAD, the index's tree, and the tree of everything in the worktree
      # but ignored files. write-tree only adds tree objects to the object
      # store; nothing is committed and the real index is not touched.
      def fingerprint(path)
        head = git!(path, "rev-parse", "HEAD").strip
        index = begin
          git!(path, "write-tree").strip
        rescue Error
          raise Error, "#{path} has unresolved merge conflicts; resolve them before moving the run"
        end
        working = Dir.mktmpdir("paneyard-index") do |dir|
          env = { "GIT_INDEX_FILE" => File.join(dir, "index") }
          git!(path, "read-tree", "HEAD", env:)
          git!(path, "add", "--all", ".", env:)
          git!(path, "write-tree", env:).strip
        end
        { "head" => head, "index" => index, "worktree" => working }
      end

      def untracked(path)
        git!(path, "ls-files", "--others", "--exclude-standard", "-z").split("\0").reject { |file| file.end_with?("/") }
      end

      # A tar of `files` (relative to path), regular files and symlinks with
      # their modes. Pure Ruby, so it reads the same on Linux and macOS.
      def tar(path, files)
        io = StringIO.new("".b)
        Gem::Package::TarWriter.new(io) do |writer|
          files.each do |file|
            full = File.join(path.to_s, file)
            stat = File.lstat(full)
            if stat.symlink?
              writer.add_symlink(file, File.readlink(full), 0o777)
            elsif stat.file?
              writer.add_file_simple(file, stat.mode & 0o777, stat.size) { |entry| entry.write(File.binread(full)) }
            end
          end
        end
        io.string
      rescue Gem::Package::TooLongFileName => error
        raise Error, "An untracked file's path is too long to move: #{error.message}"
      end

      # Unpacks export's tar into target, refusing anything that would land
      # outside it or on top of a file already there.
      def untar!(target, archive)
        root = File.realpath(target.to_s)
        Gem::Package::TarReader.new(StringIO.new(archive.b)) do |reader|
          reader.each do |entry|
            name = entry.full_name
            parts = name.split("/")
            if name.start_with?("/") || parts.include?("..") || parts.include?(".git") || parts.empty?
              raise Error, "Refusing to unpack #{name.inspect} outside the worktree"
            end

            destination = File.join(root, name)
            parent = File.dirname(destination)
            FileUtils.mkdir_p(parent)
            unless File.realpath(parent) == root || File.realpath(parent).start_with?("#{root}/")
              raise Error, "Refusing to unpack #{name.inspect} through a symlink out of the worktree"
            end
            raise Error, "Refusing to unpack #{name.inspect} over a file already in the worktree" if File.exist?(destination) || File.symlink?(destination)

            if entry.symlink?
              File.symlink(entry.header.linkname, destination)
            elsif entry.file?
              File.binwrite(destination, entry.read.to_s)
              File.chmod(entry.header.mode & 0o777, destination)
            end
          end
        end
      end

      def text(string)
        string.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      def binary(string)
        string.to_s.dup.force_encoding(Encoding::BINARY)
      end

      def repository!(repository_path)
        repository = Pathname(repository_path.to_s)
        Sandbox.guard_path!(repository, "move a run's work in")
        raise Error, "Repository does not exist: #{repository}" unless repository.directory?

        repository
      rescue Sandbox::Violation => error
        raise Error, error.message
      end

      def commit?(repository, rev)
        git_success?(repository, "rev-parse", "--verify", "--quiet", "#{rev}^{commit}")
      end

      def ancestor?(repository, ancestor, descendant)
        git_success?(repository, "merge-base", "--is-ancestor", ancestor, descendant)
      end

      def origin?(repository)
        git_success?(repository, "remote", "get-url", "origin")
      end

      # A plain `git fetch origin`, which only updates remote-tracking refs,
      # with no prompt and a deadline. A sandbox fetches only from an origin
      # inside its root.
      def fetch_origin!(repository)
        url = git!(repository, "remote", "get-url", "origin").strip
        begin
          Sandbox.guard_git_remote!(Worktrees.local_remote_path(repository, url))
        rescue Sandbox::Violation => error
          raise Error, error.message
        end

        Open3.popen3({ "GIT_TERMINAL_PROMPT" => "0" }, "git", "-C", repository.to_s, "-c", "credential.interactive=false",
          "fetch", "--quiet", "--no-tags", "origin", pgroup: true) do |input, output, errors, process|
          input.close
          readers = [ Thread.new { output.read }, Thread.new { errors.read } ]
          begin
            Timeout.timeout(FETCH_TIMEOUT) do
              raise Error, "git fetch origin failed in #{repository}: #{readers.last.value.strip}" unless process.value.success?
            end
          rescue Timeout::Error
            begin
              Process.kill("KILL", -process.pid)
            rescue Errno::ESRCH
              nil
            end
            raise Error, "git fetch origin timed out in #{repository}"
          ensure
            readers.each(&:join)
          end
        end
      end

      def capture(root, *args, stdin: nil, env: {})
        Open3.capture3(env, "git", "-C", root.to_s, *args, stdin_data: stdin.to_s, binmode: true)
      end

      def git_success?(root, *args)
        capture(root, *args).last.success?
      end

      def git!(root, *args, stdin: nil, env: {})
        output, error, status = capture(root, *args, stdin:, env:)
        return output if status.success?

        raise Error, "git #{args.reject { |arg| arg.include?('=') || arg == '-c' }.first(3).join(' ')} failed in #{root}: #{(error.presence || output).to_s.scrub.strip}"
      end
    end
  end
end
