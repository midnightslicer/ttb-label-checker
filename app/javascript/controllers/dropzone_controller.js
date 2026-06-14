import { Controller } from "@hotwired/stimulus"

// Enhances a file input into a drag-and-drop zone with image previews.
//
// The native <input> is hidden and kept in sync via a DataTransfer object so
// the form still submits the right files. Behaviour depends on the input's
// `multiple` attribute:
//   - single  : a new file replaces the current one.
//   - multiple: dropped/picked files accumulate (drag several at once, or one
//               at a time). Duplicates (same name/size/mtime) are ignored.
// Each preview has a remove button.
export default class extends Controller {
  static targets = ["input", "previews"]

  connect() {
    this.multiple = this.inputTarget.multiple
    this.files = []
    this.urls = []
    this.dragDepth = 0
    // Sync in case the browser restored a selection on back/forward.
    if (this.inputTarget.files.length) this.addFiles(this.inputTarget.files)
  }

  disconnect() {
    this.revokeUrls()
  }

  browse() {
    this.inputTarget.click()
  }

  dragOver(event) {
    event.preventDefault()
  }

  dragEnter(event) {
    event.preventDefault()
    this.dragDepth++
    this.element.classList.add("is-dragging")
  }

  dragLeave() {
    this.dragDepth--
    if (this.dragDepth <= 0) {
      this.dragDepth = 0
      this.element.classList.remove("is-dragging")
    }
  }

  drop(event) {
    event.preventDefault()
    this.dragDepth = 0
    this.element.classList.remove("is-dragging")
    this.addFiles(event.dataTransfer.files)
  }

  // Fired (via change bubbling) when files are chosen through the dialog.
  selected() {
    this.addFiles(this.inputTarget.files)
  }

  addFiles(fileList) {
    const incoming = Array.from(fileList || [])
    if (!incoming.length) return

    if (this.multiple) {
      for (const file of incoming) {
        if (!this.files.some((existing) => sameFile(existing, file))) {
          this.files.push(file)
        }
      }
    } else {
      this.files = [incoming[incoming.length - 1]]
    }

    this.syncInput()
    this.render()
  }

  removeAt(index) {
    this.files.splice(index, 1)
    this.syncInput()
    this.render()
  }

  // Write our file list back into the real input so the form submits it.
  syncInput() {
    const data = new DataTransfer()
    this.files.forEach((file) => data.items.add(file))
    this.inputTarget.files = data.files
  }

  render() {
    this.revokeUrls()
    this.previewsTarget.innerHTML = ""
    this.element.classList.toggle("has-files", this.files.length > 0)

    this.files.forEach((file, index) => {
      const thumb = document.createElement("figure")
      thumb.className = "dropzone-thumb"

      if (file.type.startsWith("image/")) {
        const url = URL.createObjectURL(file)
        this.urls.push(url)
        const img = document.createElement("img")
        img.src = url
        img.alt = file.name
        thumb.appendChild(img)
      } else {
        const badge = document.createElement("div")
        badge.className = "dropzone-thumb-file"
        badge.textContent = (file.name.split(".").pop() || "file").toUpperCase()
        thumb.appendChild(badge)
      }

      const caption = document.createElement("figcaption")
      caption.textContent = file.name
      thumb.appendChild(caption)

      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "dropzone-remove"
      remove.setAttribute("aria-label", `Remove ${file.name}`)
      remove.textContent = "×"
      remove.addEventListener("click", (event) => {
        event.stopPropagation()
        this.removeAt(index)
      })
      thumb.appendChild(remove)

      this.previewsTarget.appendChild(thumb)
    })
  }

  revokeUrls() {
    this.urls.forEach((url) => URL.revokeObjectURL(url))
    this.urls = []
  }
}

function sameFile(a, b) {
  return a.name === b.name && a.size === b.size && a.lastModified === b.lastModified
}
