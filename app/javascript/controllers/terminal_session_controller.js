import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"

// Bridges a TerminalSession's pty to xterm.js over the TerminalSessionChannel.
// Output is a broadcast the channel replays-then-streams; input/resize are
// sent back over the same subscription (see
// app/channels/terminal_session_channel.rb).
export default class extends Controller {
  static values = { id: Number }

  connect() {
    const style = getComputedStyle(document.documentElement)
    const cssColor = (name, fallback) => style.getPropertyValue(name).trim() || fallback

    this.terminal = new Terminal({
      convertEol: true,
      cursorBlink: true,
      fontSize: 13,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      theme: {
        background: "#000000",
        foreground: cssColor("--text", "#e6e8eb"),
        cursor: cssColor("--accent", "#5b8cff"),
        selectionBackground: "rgba(91, 140, 255, 0.35)"
      }
    })
    this.fitAddon = new FitAddon()
    this.terminal.loadAddon(this.fitAddon)
    this.terminal.open(this.element)

    // fit() measures cell size from the rendered font -- calling it before a
    // custom (non-system) fontFamily has actually finished loading measures
    // fallback-font metrics instead, so the initial cols/rows come out
    // wrong and only self-correct once the real font swaps in and a later
    // resize happens to fire. Waiting for fonts.ready first is the standard
    // fix recommended for any xterm.js integration using a custom font.
    document.fonts.ready.then(() => this.scheduleResize())
    this.fitAddon.fit()
    this.forceRepaint()

    this.consumer = createConsumer("/cable")
    this.subscription = this.consumer.subscriptions.create(
      { channel: "TerminalSessionChannel", id: this.idValue },
      {
        received: (message) => {
          if (message.type === "replay" || message.type === "output") this.terminal.write(message.data)
          // A fresh CLI process on the server starts at its own default
          // size, independent of whatever size this (possibly long-lived,
          // data-turbo-permanent) client last reported -- force a resend
          // even if our own visual box never changed.
          if (message.type === "size_request") {
            this.lastDims = null
            this.scheduleResize()
          }
          // fit()/resize() alone don't guarantee every cell actually gets
          // repainted -- only a real window resize reliably did, because
          // resizing forces the canvas to redraw from scratch. terminal.
          // refresh() is xterm's own API for that same forced full redraw,
          // triggered here instead of requiring the user to resize by hand.
          if (message.type === "replay" || message.type === "size_request") this.forceRepaint()
        }
      }
    )

    this.terminal.onData((data) => this.subscription.send({ type: "input", data }))

    this.lastDims = null
    this.resizeObserver = new ResizeObserver(() => this.scheduleResize())
    this.resizeObserver.observe(this.element)

    // Escape reliably never reaches xterm's own keydown handler on this
    // page (confirmed server-side: hundreds of other keys/sequences arrive,
    // never a lone escape byte) -- something upstream swallows it before
    // xterm's textarea listener ever sees the event. Intercept it ourselves
    // in the capture phase on window, as early as any listener can run, and
    // send the byte directly so the CLI still gets it regardless of that
    // cause.
    this.handleEscapeCapture = this.handleEscapeCapture.bind(this)
    window.addEventListener("keydown", this.handleEscapeCapture, true)
  }

  disconnect() {
    window.removeEventListener("keydown", this.handleEscapeCapture, true)
    cancelAnimationFrame(this.resizeFrame)
    this.resizeObserver?.disconnect()
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.terminal?.dispose()
  }

  handleEscapeCapture(event) {
    if (event.key !== "Escape") return
    if (!this.element.contains(document.activeElement)) return

    event.preventDefault()
    event.stopPropagation()
    this.subscription.send({ type: "input", data: String.fromCharCode(27) })
  }

  // xterm mounts its own DOM (rows, viewport, scrollbar) inside this.element,
  // the same node we observe -- fit() recalculating cols/rows can nudge that
  // subtree's measured size by a hair, re-triggering the observer and
  // resizing again, in a loop (confirmed server-side: rows cycling
  // 44/45/46/47 forever with cols steady, thrashing the pty's winsize
  // continuously). Coalescing to one measurement per frame and skipping a
  // resend when the computed size hasn't actually changed breaks the loop.
  scheduleResize() {
    cancelAnimationFrame(this.resizeFrame)
    this.resizeFrame = requestAnimationFrame(() => this.handleResize())
  }

  handleResize() {
    this.fitAddon.fit()
    const { cols, rows } = this.terminal
    if (this.lastDims && this.lastDims.cols === cols && this.lastDims.rows === rows) return

    this.lastDims = { cols, rows }
    this.subscription.send({ type: "resize", cols, rows })
  }

  forceRepaint() {
    if (this.terminal.rows > 0) this.terminal.refresh(0, this.terminal.rows - 1)
  }
}
