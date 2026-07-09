module Api
  class WorkersController < Api::BaseController
    def index
      scope = Worker.all
      scope = scope.where(run_id: params[:runId]) if params[:runId].present?
      scope = scope.active if ActiveModel::Type::Boolean.new.cast(params[:activeOnly])
      render json: scope.map(&:as_json)
    end

    # worker_id is client-generated (see Worker's class comment) -- create
    # is an upsert by worker_id so supervisor-loop.ts's claim-before-spawn
    # ordering (which pre-generates the id) keeps working unchanged.
    def create
      run = Run.find_or_create_for_bus!(worker_params[:runId])
      worker = Worker.find_or_initialize_by(worker_id: worker_params[:workerId])
      worker.assign_attributes(
        run_id: run.run_id,
        role: worker_params[:role],
        nickname: worker_params[:nickname],
        reason: worker_params[:reason],
        scope: worker_params[:scope],
        status: "running",
        pid: worker_params[:pid],
        prompt_path: worker_params[:promptPath],
        log_path: worker_params[:logPath],
        last_message_path: worker_params[:lastMessagePath],
        env_path: worker_params[:envPath],
        command: worker_params[:command],
        args: worker_params[:args] || []
      )
      worker.save!
      render json: worker
    end

    # Covers both an explicit, reasoned stop and Node's own refreshWorkers()
    # PATCHing in an observed crash -- both are "mark this worker stopped",
    # just with a different reason string.
    def stop
      worker = Worker.find_by!(worker_id: params[:id])
      worker.update!(status: "stopped", stopped_at: Time.current, stop_reason: params[:reason])
      render json: worker
    end

    private

    # Brakeman flags :command/:role here as "dangerous keys for mass
    # assignment" -- both are plain descriptive strings mirroring
    # WorkflowWorkerRecord's command/role fields (e.g. "codex" or "worker"),
    # stored for display only. Neither is ever interpolated into a shell
    # command or exec call from Ruby -- actual process spawning happens
    # exclusively in Node (LaunchRunJob spawns the supervisor loop; the
    # loop itself forks workers), never from data read back out of this
    # table.
    def worker_params
      params.permit(
        :runId, :workerId, :role, :nickname, :reason, :scope, :pid,
        :promptPath, :logPath, :lastMessagePath, :envPath, :command, args: []
      )
    end
  end
end
