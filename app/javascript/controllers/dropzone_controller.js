import { Controller } from "@hotwired/stimulus"

// Progressively enhances a file input into a drag-and-drop zone.
// The real <input type="file"> sits transparently on top of the zone, so
// native click-to-browse and drag-and-drop work; this controller just adds
// the drag highlight and shows the selected filename(s).
export default class extends Controller {
  static targets = ["input", "filename"]

  enter(event) {
    event.preventDefault()
    this.element.classList.add("is-dragging")
  }

  leave() {
    this.element.classList.remove("is-dragging")
  }

  changed() {
    this.leave()
    const files = Array.from(this.inputTarget.files || [])
    const el = this.filenameTarget

    if (!files.length) {
      el.textContent = el.dataset.placeholder || ""
      this.element.classList.remove("has-files")
      return
    }

    el.textContent = files.length === 1 ? files[0].name : `${files.length} files selected`
    this.element.classList.add("has-files")
  }
}
