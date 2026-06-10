import { Controller } from "@hotwired/stimulus"

// Plays the success-check appear animation on connect: the stroke length
// is measured per-path so the draw starts exactly at zero.
export default class extends Controller {
  connect() {
    this.element.querySelectorAll("svg path").forEach(path => {
      const length = Math.ceil(path.getTotalLength()) + 1
      path.style.strokeDasharray = String(length)
      path.style.strokeDashoffset = String(length)
    })

    requestAnimationFrame(() => (this.element.dataset.state = "in"))
  }
}
