import { Controller } from "@hotwired/stimulus"

// Background-polls the current page while work is in progress, swapping in only
// the region that changed. Unlike a <meta http-equiv="refresh"> full reload,
// this preserves scroll position and text selection, and doesn't restart CSS
// spinners — when the fetched content is identical (still processing) the DOM is
// left completely untouched. Polling stops once the server reports no active
// work (data-refresh-active-value="false" in the freshly fetched page).
//
// Markup: put data-controller="refresh" and data-refresh-active-value on a
// container, and mark the dynamic part inside it with [data-refresh-region].
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 5000 },
    active: Boolean,
  }

  connect() {
    if (this.activeValue) this.schedule()
  }

  disconnect() {
    this.stop()
  }

  schedule() {
    this.stop()
    this.timer = setTimeout(() => this.refresh(), this.intervalValue)
  }

  stop() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }

  async refresh() {
    // Skip while the tab is hidden; we'll catch up when it's visible again.
    if (document.hidden) return this.schedule()

    let stillActive = true
    try {
      const response = await fetch(window.location.href, { cache: "no-store" })
      if (!response.ok) return this.schedule()

      const doc = new DOMParser().parseFromString(await response.text(), "text/html")

      const incoming = doc.querySelector("[data-refresh-region]")
      const current = this.element.querySelector("[data-refresh-region]")
      if (incoming && current && incoming.innerHTML !== current.innerHTML) {
        current.innerHTML = incoming.innerHTML
      }

      const root = doc.querySelector("[data-controller~='refresh']")
      stillActive = root?.getAttribute("data-refresh-active-value") === "true"
    } catch (_error) {
      // Network blip — keep trying.
    }

    if (stillActive) this.schedule()
  }
}
