// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
//
// Turbo is intentionally NOT imported. This app polls for results with native
// <meta http-equiv="refresh"> tags (batches index, review show, reviews index).
// Turbo Drive swaps page bodies without unloading the document, which leaves
// those refresh timers armed after navigation and bounces the user back. We
// only need Stimulus here (for the upload dropzone), so load just that.
import "controllers"
