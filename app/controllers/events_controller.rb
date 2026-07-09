class EventsController < ApplicationController
  def index
    @events = BusEvent.order(created_at: :desc).limit(25).to_a.reverse.map { |event| JSON.parse(event.to_json) }
  end
end
