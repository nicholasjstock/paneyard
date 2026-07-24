# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "@xterm/addon-fit", to: "@xterm--addon-fit.js" # @0.11.0
pin "@rails/actioncable", to: "@rails--actioncable.js" # @8.1.300
pin "@xterm/xterm", to: "@xterm--xterm.js" # @6.0.0
