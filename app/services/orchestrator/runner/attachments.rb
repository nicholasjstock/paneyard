module Orchestrator
  module Runner
    # Files the operator attached to a run at launch, kept on the runner's
    # machine under the workspace's main checkout
    # (<main>/.workflow-orchestrator/artifacts/<run>/), since that is where
    # the session can read them. They are stored before the run's worktree
    # exists, which is why they live under main rather than the worktree.
    module Attachments
      module_function

      OUTPUT_DIR = File.join(".workflow-orchestrator", "artifacts")

      def dir(source_root, run_id)
        File.join(source_root, OUTPUT_DIR, sanitize_run_id(run_id))
      end

      def sanitize_run_id(run_id)
        sanitized = run_id.to_s.strip.gsub(/[^A-Za-z0-9._-]/, "_")
        raise ArgumentError, "run_id must not be empty" if sanitized.empty?

        sanitized
      end

      def path(source_root, run_id, name)
        if name.blank? || name == "." || name == ".." || name.include?("/") || name.include?("\\") || name.include?("\0")
          raise ArgumentError, "Unsafe attachment name: #{name}"
        end

        File.join(dir(source_root, run_id), name)
      end

      def store(source_root, run_id, name, content)
        path = path(source_root, run_id, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
        path
      end

      # [{ "name", "content" }], by name.
      def list(source_root, run_id)
        run_dir = dir(source_root, run_id)
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
