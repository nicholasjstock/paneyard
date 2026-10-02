module Orchestrator
  module Runner
    # Files the operator attached to a run at launch, kept on the runner's
    # machine beside the run's other runtime files
    # (<runtime root>/<run>/attachments/), where the session is told to read
    # them. Never inside the repository: that is the operator's own checkout,
    # and a file left there would show up as untracked work.
    #
    # Runs from before kept them in <checkout>/.paneyard/artifacts/<run>/;
    # list still reads that for them.
    module Attachments
      module_function

      LEGACY_DIR = File.join(".paneyard", "artifacts")

      def dir(runtime_root, run_id)
        File.join(runtime_root.to_s, sanitize_run_id(run_id), "attachments")
      end

      def sanitize_run_id(run_id)
        sanitized = run_id.to_s.strip.gsub(/[^A-Za-z0-9._-]/, "_")
        raise ArgumentError, "run_id must not be empty" if sanitized.empty?

        sanitized
      end

      def path(runtime_root, run_id, name)
        if name.blank? || name == "." || name == ".." || name.include?("/") || name.include?("\\") || name.include?("\0")
          raise ArgumentError, "Unsafe attachment name: #{name}"
        end

        File.join(dir(runtime_root, run_id), name)
      end

      def store(runtime_root, run_id, name, content)
        path = path(runtime_root, run_id, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
        path
      end

      # [{ "name", "content" }], by name.
      def list(runtime_root, run_id, legacy_root: nil)
        run_dir = dir(runtime_root, run_id)
        legacy = legacy_root && File.join(legacy_root.to_s, LEGACY_DIR, sanitize_run_id(run_id))
        run_dir = legacy if !Dir.exist?(run_dir) && legacy && Dir.exist?(legacy)
        return [] unless Dir.exist?(run_dir)

        Dir.children(run_dir).sort.filter_map do |name|
          file = File.join(run_dir, name)
          { "name" => name, "content" => File.read(file) } if File.file?(file)
        end
      rescue Errno::ENOENT
        []
      end
    end
  end
end
