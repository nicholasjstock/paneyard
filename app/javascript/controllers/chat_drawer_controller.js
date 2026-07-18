import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "thread", "input"]

  connect() {
    this.setOpen(sessionStorage.getItem(this.storageKey) === "open")
    const draft = sessionStorage.getItem(this.draftStorageKey)
    if (draft !== null && this.hasInputTarget) this.inputTarget.value = draft
  }

  open() {
    this.setOpen(true)
    sessionStorage.setItem(this.storageKey, "open")
    requestAnimationFrame(() => { this.threadTarget.scrollTop = this.threadTarget.scrollHeight })
  }

  close() {
    this.setOpen(false)
    sessionStorage.removeItem(this.storageKey)
  }

  beforeMorph(event) {
    if (event.target === this.element) {
      event.detail.newElement.classList.toggle("chat-open", this.element.classList.contains("chat-open"))
      this.copyDraftTo(event.detail.newElement.querySelector("textarea[data-chat-drawer-target='input']"))
      return
    }

    if (this.hasInputTarget && event.target === this.inputTarget) this.copyDraftTo(event.detail.newElement)
  }

  saveDraft() {
    if (this.hasInputTarget) sessionStorage.setItem(this.draftStorageKey, this.inputTarget.value)
  }

  clearDraft() {
    sessionStorage.removeItem(this.draftStorageKey)
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return

    event.preventDefault()
    event.currentTarget.form.requestSubmit()
  }

  copyDraftTo(input) {
    if (!input || !this.hasInputTarget) return

    input.value = this.inputTarget.value
    input.textContent = this.inputTarget.value
  }

  setOpen(open) {
    this.element.classList.toggle("chat-open", open)
    this.panelTarget.setAttribute("aria-hidden", open ? "false" : "true")
  }

  get storageKey() {
    return `workspace-chat:${window.location.pathname}`
  }

  get draftStorageKey() {
    return `${this.storageKey}:draft`
  }
}
