class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  # No auth in v1 (single-user local tool) -- placeholder for whoever is
  # at the keyboard, kept as a distinct concept so it's easy to wire up
  # real auth later without touching the rest of the launch/answer flows.
  def current_operator
    "operator"
  end
end
