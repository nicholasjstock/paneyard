class EventsController < ApplicationController
  before_action :require_workspace

  def index
    @events = BusEvent.joins(:run)
      .where(runs: { workspace_id: current_workspace.id })
      .order(created_at: :desc)
      .limit(25)
      .to_a
      .reverse
      .map { |event| JSON.parse(event.to_json) }
  end
end
