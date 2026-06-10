import { Controller } from "@hotwired/stimulus"

// Registers the service worker. Attached to <body> so it runs on the initial
// load; re-registration on Turbo visits is a no-op the browser dedupes.
export default class extends Controller {
  connect() {
    if (!("serviceWorker" in navigator)) return

    navigator.serviceWorker
      .register("/service-worker.js", { scope: "/" })
      .catch(error => console.error("Service worker registration failed:", error))
  }
}
