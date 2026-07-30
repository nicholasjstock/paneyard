import { Controller } from "@hotwired/stimulus"

// Ports the pre-terminal WorkspaceChat drawer controller (see git history:
// "Replace one-shot workspace chat with a real, resumable terminal
// session") for the admin chat's floating launcher + modal, which is
// workspace-wide again rather than scoped to a single run page. Draft text
// and open/closed state persist in sessionStorage per pathname so a Turbo
// Stream refresh (broadcast_refresh_to on every streamed event) or a full
// navigation back to the same page don't lose either.
export default class extends Controller {
  static targets = ["panel", "thread", "input", "providerSelect", "claudeModelSelect", "codexModelSelect", "opencodeModelSelect"]

  connect() {
    this.setOpen(sessionStorage.getItem(this.storageKey) === "open")
    const draft = sessionStorage.getItem(this.draftStorageKey)
    if (draft !== null && this.hasInputTarget) this.inputTarget.value = draft
    this.syncModelPicker()
    this.scrollToBottomIfOpen()
  }

  // The provider select is shared by one settings form that submits both
  // model selects regardless of which is visible (harmless -- the server
  // only reads the model belonging to whichever provider is actually
  // active) -- this just shows/hides which one matches the current pick.
  syncModelPicker() {
    if (!this.hasProviderSelectTarget) return

    const provider = this.providerSelectTarget.value
    if (this.hasClaudeModelSelectTarget) this.claudeModelSelectTarget.hidden = provider !== "claude"
    if (this.hasCodexModelSelectTarget) this.codexModelSelectTarget.hidden = provider !== "codex"
    if (this.hasOpencodeModelSelectTarget) this.opencodeModelSelectTarget.hidden = provider !== "opencode"
  }

  // No Save button -- a settings select submits itself the moment it
  // changes, and the server's response (a full redirect_back) re-renders
  // this drawer from the just-persisted state, so reopening it later always
  // shows exactly what was last picked.
  submitSettings(event) {
    event.target.form.requestSubmit()
  }

  open() {
    this.setOpen(true)
    sessionStorage.setItem(this.storageKey, "open")
    this.scrollToBottomIfOpen()
  }

  close() {
    this.setOpen(false)
    sessionStorage.removeItem(this.storageKey)
  }

  // chat.rb/message.rb both broadcast_refresh_to on every streamed event, so
  // a turn in progress triggers many Turbo page-refresh morphs a second --
  // each one fully re-renders the thread section, which resets a plain
  // scrollTop to 0 same as any other DOM content replacement. turbo:render
  // fires after both a full visit *and* a morph refresh (unlike turbo:load,
  // which only fires for a full visit), so re-pinning to the bottom there
  // keeps the transcript glued to the latest line through an entire turn
  // instead of snapping back to the oldest message on every tick.
  scrollToBottomIfOpen() {
    if (!this.hasThreadTarget) return
    if (!this.element.classList.contains("chat-open")) return

    requestAnimationFrame(() => { this.threadTarget.scrollTop = this.threadTarget.scrollHeight })
  }

  beforeMorph(event) {
    if (event.target === this.element) {
      event.detail.newElement.classList.toggle("chat-open", this.element.classList.contains("chat-open"))
      this.copyDraftTo(event.detail.newElement.querySelector("textarea[data-admin-chat-drawer-target='input']"))
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
    return `admin-chat:${window.location.pathname}`
  }

  get draftStorageKey() {
    return `${this.storageKey}:draft`
  }
}
