module Api
  class EventsController < Api::BaseController
    def index
      limit = (params[:limit].presence || 20).to_i.clamp(1, 200)
      events = BusEvent.order(created_at: :desc).limit(limit).to_a.reverse
      render json: { events: events.map(&:as_json) }
    end
  end
end
