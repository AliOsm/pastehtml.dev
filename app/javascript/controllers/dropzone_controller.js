import { Controller } from "@hotwired/stimulus"

const MAX_BYTES = 2 * 1024 * 1024

// Drives the upload drop zone: browsing, drag-and-drop, client-side
// validation with an error shake, and the busy state while publishing.
export default class extends Controller {
  static targets = ["input", "zone", "wrap", "error", "heading", "hint", "publish", "publishHint"]
  // User-facing messages are translated server-side and handed in as values, so
  // the controller stays locale-agnostic.
  static values = {
    notHtmlFile: String,
    empty: String,
    tooLarge: String,
    notHtmlClipboard: String,
    // Guests have no options to set, so a file selection publishes immediately.
    // Signed-in users get to set a subdomain/password/folder first, so it only
    // loads the file and shows the `selected` prompt until they hit Publish.
    autoSubmit: Boolean,
    selected: String,
  }

  connect() {
    if (this.errorTarget.textContent.trim()) this.showError()
    this.reflectPublishState()
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
      this.errorTarget.textContent = this.notHtmlClipboardValue
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

    if (this.autoSubmitValue) {
      this.element.requestSubmit()
    } else {
      this.reflectSelection(file)
    }
  }

  // Signed-in users publish explicitly, so a selection just loads the file and
  // swaps the prompt for the file name and a "set options, then Publish" hint.
  reflectSelection(file) {
    if (this.hasHeadingTarget) this.headingTarget.textContent = file.name
    if (this.hasHintTarget) this.hintTarget.textContent = this.selectedValue
    this.reflectPublishState()
  }

  // Signed-in users publish explicitly: keep the button disabled (with a hint)
  // until a file is loaded, so pressing it with no file can't fire a doomed
  // submit that just bounces them to the top of the page.
  reflectPublishState() {
    if (!this.hasPublishTarget) return
    const hasFile = this.inputTarget.files.length > 0
    this.publishTarget.disabled = !hasFile
    if (this.hasPublishHintTarget) this.publishHintTarget.hidden = hasFile
  }

  problemWith(file) {
    if (!/\.(html?|md|markdown)$/i.test(file.name)) return this.notHtmlFileValue
    if (file.size === 0) return this.emptyValue
    if (file.size > MAX_BYTES) return this.tooLargeValue
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
