# No auth in v1 (single-user local tool), matching
# ApplicationController#current_operator -- placeholder for whoever is at
# the keyboard, kept distinct so real auth is easy to wire up later.
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :operator

    def connect
      self.operator = "operator"
    end
  end
end
