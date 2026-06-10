import { Controller } from "@hotwired/stimulus"

const MAX_BYTES = 2 * 1024 * 1024

// Drives the upload drop zone: browsing, drag-and-drop, client-side
// validation with an error shake, and the busy state while publishing.
export default class extends Controller {
  static targets = ["input", "zone", "wrap", "error"]

  connect() {
    if (this.errorTarget.textContent.trim()) this.showError()
  }

  disconnect() {
    clearTimeout(this.shakeTimer)
    clearTimeout(this.revertTimer)
  }

  browse() {
    this.inputTarget.click()
  }

  dragOver(event) {
    event.preventDefault()
    this.zoneTarget.dataset.dragging = ""
  }

  dragLeave(event) {
    event.preventDefault()
    delete this.zoneTarget.dataset.dragging
  }

  drop(event) {
    event.preventDefault()
    delete this.zoneTarget.dataset.dragging

    const file = event.dataTransfer.files[0]
    if (file) this.submit(file)
  }

  fileSelected() {
    const file = this.inputTarget.files[0]
    if (file) this.submit(file)
  }

  // Publish straight from the clipboard: a file copied in Finder/Explorer
  // arrives in clipboardData.files; copied HTML source arrives as text.
  pasted(event) {
    if (event.target.closest?.("input, textarea, [contenteditable]")) return

    const file = event.clipboardData?.files?.[0]
    if (file) {
      event.preventDefault()
      this.submit(file)
      return
    }

    const source = (event.clipboardData?.getData("text/plain") ?? "").trim()
    if (!source) return

    event.preventDefault()

    if (!source.startsWith("<")) {
      this.errorTarget.textContent = "The clipboard doesn't look like HTML. It should start with a tag."
      this.showError()
      return
    }

    this.submit(new File([source], "pasted.html", { type: "text/html" }))
  }

  uploading() {
    this.element.dataset.busy = ""
  }

  submit(file) {
    const problem = this.problemWith(file)

    if (problem) {
      this.inputTarget.value = ""
      this.errorTarget.textContent = problem
      this.showError()
      return
    }

    if (this.inputTarget.files[0] !== file) {
      const transfer = new DataTransfer()
      transfer.items.add(file)
      this.inputTarget.files = transfer.files
    }

    this.element.requestSubmit()
  }

  problemWith(file) {
    if (!/\.html?$/i.test(file.name)) return "That doesn't look like an HTML file. Choose a .html or .htm file."
    if (file.size === 0) return "That file is empty."
    if (file.size > MAX_BYTES) return "That file is larger than 2 MB."
    return null
  }

  showError() {
    this.wrapTarget.classList.add("is-error")
    this.zoneTarget.classList.add("is-error")

    // Replay the shake from a clean baseline.
    this.zoneTarget.classList.remove("is-shaking")
    void this.zoneTarget.offsetWidth
    this.zoneTarget.classList.add("is-shaking")

    clearTimeout(this.shakeTimer)
    this.shakeTimer = setTimeout(() => this.zoneTarget.classList.remove("is-shaking"), this.shakeMs + 20)

    clearTimeout(this.revertTimer)
    this.revertTimer = setTimeout(() => {
      this.wrapTarget.classList.remove("is-error")
      this.zoneTarget.classList.remove("is-error")
    }, this.shakeMs + this.cssMs("--revert-hold", 3000))
  }

  get shakeMs() {
    return this.cssMs("--shake-dur-a", 80) * 2 + this.cssMs("--shake-dur-b", 60) * 2
  }

  cssMs(name, fallback) {
    const value = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name))
    return Number.isFinite(value) ? value : fallback
  }
}
