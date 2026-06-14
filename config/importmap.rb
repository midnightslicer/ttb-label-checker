# Pin npm packages by running ./bin/importmap

pin "application"
# Turbo is pinned but intentionally not imported (see app/javascript/application.js).
pin "@hotwired/turbo-rails", to: "turbo.min.js", preload: false
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
