import { Controller } from "@hotwired/stimulus"

// Expands the preview panel to fill the viewport while staying inside the
// site chrome. The panel FLIP-morphs between its inline spot and the
// overlay: on open it visibly grows out of the page, on close it shrinks
// back into its reserved slot — it is never removed and re-added visually.
// The iframe never moves in the DOM, so it never reloads.
//
// The slot's height is frozen while the panel is out of the layout flow,
// so the page neither reflows nor scrolls around the overlay, and the
// slot's rect stays a reliable FLIP destination for the close morph.
export default class extends Controller {
  static targets = ["slot", "panel", "swap"]

  disconnect() {
    clearTimeout(this.closeTimer)
    clearTimeout(this.morphTimer)
    delete this.element.dataset.fullscreen
    delete this.element.dataset.closing
    this.swapLabel("a")
    this.unpin()
    this.unfreezeSlot()
    document.body.style.overflow = ""
  }

  toggle() {
    this.element.hasAttribute("data-fullscreen") ? this.exit() : this.enter()
  }

  // Plain "f" toggles fullscreen — but never while typing in a field,
  // never with a modifier held (so Cmd/Ctrl+F stays find-in-page), and
  // never while the preview panel is hidden behind the source tab.
  keyToggle(event) {
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return
    if (event.target.closest?.("input, textarea, select, [contenteditable]")) return
    if (this.element.closest("[hidden]")) return

    this.toggle()
  }

  enter() {
    if (this.element.hasAttribute("data-fullscreen")) return

    clearTimeout(this.closeTimer)
    delete this.element.dataset.closing

    const first = this.panelTarget.getBoundingClientRect()
    this.freezeSlot()
    this.element.dataset.fullscreen = ""
    document.body.style.overflow = "hidden"
    this.swapLabel("b")
    const last = this.panelTarget.getBoundingClientRect()
    this.morph(first, last, this.openMs)
  }

  exit() {
    if (!this.element.hasAttribute("data-fullscreen")) return
    if (this.element.hasAttribute("data-closing")) return

    this.element.dataset.closing = ""
    this.swapLabel("a")
    this.morph(this.panelTarget.getBoundingClientRect(), this.slotTarget.getBoundingClientRect(), this.closeMs)

    clearTimeout(this.closeTimer)
    this.closeTimer = setTimeout(() => {
      delete this.element.dataset.fullscreen
      delete this.element.dataset.closing
      this.unpin()
      this.unfreezeSlot()
      document.body.style.overflow = ""
    }, this.closeMs)
  }

  // Window-zoom morph: pin the panel at its current rect with position:fixed,
  // then transition its real geometry to the destination rect. Animating
  // width/height instead of a scale transform means the toolbar keeps its
  // natural size throughout and the iframe resizes like a real window —
  // nothing inside the panel ever stretches or squishes.
  morph(from, to, duration) {
    if (this.reducedMotion) return

    const panel = this.panelTarget
    clearTimeout(this.morphTimer)
    panel.style.transition = "none"
    this.pin(from)
    void panel.offsetWidth
    panel.style.transition = ["top", "left", "width", "height"]
      .map(property => `${property} ${duration}ms ${this.ease}`).join(", ")
    this.pin(to)

    this.morphTimer = setTimeout(() => this.unpin(), duration + 20)
  }

  pin(rect) {
    const style = this.panelTarget.style
    style.position = "fixed"
    style.top = `${rect.top}px`
    style.left = `${rect.left}px`
    style.width = `${rect.width}px`
    style.height = `${rect.height}px`
  }

  swapLabel(state) {
    if (this.hasSwapTarget) this.swapTarget.dataset.state = state
  }

  unpin() {
    if (!this.hasPanelTarget) return

    const style = this.panelTarget.style
    style.transition = ""
    style.position = ""
    style.top = ""
    style.left = ""
    style.width = ""
    style.height = ""
  }

  freezeSlot() {
    if (this.hasSlotTarget) this.slotTarget.style.height = `${this.slotTarget.offsetHeight}px`
  }

  unfreezeSlot() {
    if (this.hasSlotTarget) this.slotTarget.style.height = ""
  }

  get openMs() {
    return this.cssMs("--modal-open-dur", 300)
  }

  get closeMs() {
    return this.cssMs("--modal-close-dur", 240)
  }

  get ease() {
    return getComputedStyle(document.documentElement).getPropertyValue("--modal-ease").trim() ||
      "cubic-bezier(0.22, 1, 0.36, 1)"
  }

  get reducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }

  cssMs(name, fallback) {
    const value = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name))
    return Number.isFinite(value) ? value : fallback
  }
}
