import { Controller } from "@hotwired/stimulus"

// Generic slide-over open/close, extracted from the old chat-specific
// drawer controller once its draft-persistence (chat composer only) moved
// out with WorkspaceChat.
export default class extends Controller {
  static targets = ["panel"]

  connect() {
    this.setOpen(sessionStorage.getItem(this.storageKey) === "open")
  }

  open() {
    this.setOpen(true)
    sessionStorage.setItem(this.storageKey, "open")
  }

  close() {
    this.setOpen(false)
    sessionStorage.removeItem(this.storageKey)
  }

  beforeMorph(event) {
    if (event.target !== this.element) return

    event.detail.newElement.classList.toggle("chat-open", this.element.classList.contains("chat-open"))
  }

  setOpen(open) {
    this.element.classList.toggle("chat-open", open)
    this.panelTarget.setAttribute("aria-hidden", open ? "false" : "true")
  }

  get storageKey() {
    return `terminal-drawer:${window.location.pathname}`
  }
}
