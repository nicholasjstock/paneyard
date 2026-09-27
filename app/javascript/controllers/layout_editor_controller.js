import { Controller } from "@hotwired/stimulus"

// The workspace form's layout editor (Orchestrator::WorkspaceLayout): tabs,
// each a list of panes where every pane after the tab's first is split off an
// earlier pane in the same tab. The agent is fixed as the first pane of the
// first tab. The editor keeps its own copy of the layout and writes it into
// the hidden `layout` field as JSON on every change; Workspace validates and
// stores it. The field stays blank -- the default layout -- until something
// is actually changed, or after "Reset to default".
const AGENT = "agent"

export default class extends Controller {
  static targets = ["input", "tabs", "status", "reset"]
  static values = { tabs: Array, defaultTabs: Array, usingDefault: Boolean }

  connect() {
    this.tabs = structuredClone(this.tabsValue)
    this.usingDefault = this.usingDefaultValue
    this.render()
  }

  // --- structural edits (re-render everything) ---

  addTab() {
    this.tabs.push({ name: "", panes: [ { name: this.uniqueName("shell"), command: "" } ] })
    this.changed({ rerender: true })
  }

  removeTab(tabIndex) {
    this.tabs.splice(tabIndex, 1)
    this.changed({ rerender: true })
  }

  moveTab(tabIndex, offset) {
    const target = tabIndex + offset
    if (target < 1 || target >= this.tabs.length) return
    const [ tab ] = this.tabs.splice(tabIndex, 1)
    this.tabs.splice(target, 0, tab)
    this.changed({ rerender: true })
  }

  addPane(tabIndex) {
    const panes = this.tabs[tabIndex].panes
    const pane = { name: this.uniqueName("pane"), command: "" }
    if (panes.length > 0) pane.split = { of: panes[panes.length - 1].name, direction: "right" }
    panes.push(pane)
    this.changed({ rerender: true })
  }

  // Panes split off the removed one are re-attached to whatever it was split
  // off; removing a tab's root makes the next pane the root.
  removePane(tabIndex, paneIndex) {
    const panes = this.tabs[tabIndex].panes
    const [ removed ] = panes.splice(paneIndex, 1)
    if (paneIndex === 0 && panes.length > 0) {
      const newRoot = panes[0]
      delete newRoot.split
      for (const pane of panes.slice(1)) {
        if (pane.split?.of === removed.name) pane.split.of = newRoot.name
      }
    } else {
      for (const pane of panes) {
        if (pane.split?.of === removed.name) pane.split.of = removed.split?.of || panes[0]?.name
      }
    }
    if (panes.length === 0) this.tabs.splice(tabIndex, 1)
    this.changed({ rerender: true })
  }

  resetToDefault() {
    this.tabs = structuredClone(this.defaultTabsValue)
    this.usingDefault = true
    this.inputTarget.value = ""
    this.render()
  }

  // --- field edits (update in place, so focus is kept) ---

  renamePane(tabIndex, paneIndex, name) {
    const panes = this.tabs[tabIndex].panes
    const old = panes[paneIndex].name
    panes[paneIndex].name = name
    for (const pane of panes) {
      if (pane.split?.of === old) pane.split.of = name
    }
    this.changed()
    this.refreshSplitChoices(tabIndex)
  }

  changed({ rerender = false } = {}) {
    this.usingDefault = false
    this.inputTarget.value = JSON.stringify({ tabs: this.serialized() })
    if (rerender) {
      this.render()
    } else {
      this.renderStatus()
      this.tabs.forEach((_tab, index) => this.renderPreview(index))
    }
  }

  serialized() {
    return this.tabs.map((tab) => {
      const panes = tab.panes.map((pane) => {
        if (pane.name === AGENT) return AGENT
        const entry = { name: pane.name }
        if (pane.command?.trim()) entry.command = pane.command.trim()
        if (pane.split) {
          entry.split = { of: pane.split.of, direction: pane.split.direction || "right" }
          const ratio = parseFloat(pane.split.ratio)
          if (!Number.isNaN(ratio)) entry.split.ratio = ratio
        }
        return entry
      })
      return tab.name?.trim() ? { name: tab.name.trim(), panes } : { panes }
    })
  }

  // --- rendering ---

  render() {
    this.tabsTarget.replaceChildren(...this.tabs.map((tab, index) => this.renderTab(tab, index)))
    this.tabs.forEach((_tab, index) => this.renderPreview(index))
    this.renderStatus()
  }

  renderStatus() {
    this.statusTarget.textContent = this.usingDefault
      ? "Using the default layout. Changing anything saves this workspace's own layout."
      : "This workspace's own layout. Save the form to keep changes."
    this.resetTarget.hidden = this.usingDefault
  }

  renderTab(tab, tabIndex) {
    const card = this.el("fieldset", "card layout-tab")
    card.dataset.tabIndex = tabIndex

    const header = this.el("div", "layout-tab-header")
    const nameInput = this.input(tab.name || "", `Tab ${tabIndex + 1}`, (value) => { tab.name = value; this.changed() })
    nameInput.setAttribute("aria-label", `Tab ${tabIndex + 1} name`)
    header.append(this.el("span", "layout-tab-number", `Tab ${tabIndex + 1}`), nameInput)
    if (tabIndex > 0) {
      header.append(
        this.button("↑", () => this.moveTab(tabIndex, -1), `Move tab ${tabIndex + 1} up`, tabIndex === 1),
        this.button("↓", () => this.moveTab(tabIndex, 1), `Move tab ${tabIndex + 1} down`, tabIndex === this.tabs.length - 1),
        this.button("Remove tab", () => this.removeTab(tabIndex), `Remove tab ${tabIndex + 1}`, false, "danger")
      )
    }
    card.append(header)

    const body = this.el("div", "layout-tab-body")
    const panes = this.el("div", "layout-panes")
    tab.panes.forEach((pane, paneIndex) => panes.append(this.renderPane(tab, tabIndex, pane, paneIndex)))
    panes.append(this.button("Add pane", () => this.addPane(tabIndex), `Add pane to tab ${tabIndex + 1}`))
    const preview = this.el("div", "layout-preview")
    preview.dataset.previewFor = tabIndex
    preview.setAttribute("aria-hidden", "true")
    body.append(panes, preview)
    card.append(body)
    return card
  }

  renderPane(tab, tabIndex, pane, paneIndex) {
    const row = this.el("div", "layout-pane")

    if (pane.name === AGENT) {
      row.classList.add("layout-pane-agent")
      row.append(
        this.el("strong", null, "agent"),
        this.el("span", "muted", "The run's claude/codex/opencode session. Always here, always first.")
      )
      return row
    }

    const label = pane.name || `pane ${paneIndex + 1}`
    const name = this.input(pane.name, "name", (value) => this.renamePane(tabIndex, paneIndex, value))
    name.classList.add("layout-pane-name")
    name.setAttribute("aria-label", `Pane ${label} name`)
    const command = this.input(pane.command || "", "command (blank: plain shell)", (value) => { pane.command = value; this.changed() })
    command.classList.add("mono")
    command.setAttribute("aria-label", `Pane ${label} command`)
    const remove = this.button("Remove", () => this.removePane(tabIndex, paneIndex), `Remove pane ${label}`, false, "danger")
    row.append(name, command, remove)

    if (paneIndex > 0) {
      pane.split ||= { of: tab.panes[0].name, direction: "right" }
      const split = this.el("div", "layout-pane-split")
      const of = this.el("select")
      of.dataset.splitOf = paneIndex
      of.setAttribute("aria-label", `Pane ${label} splits`)
      this.fillSplitChoices(of, tab, paneIndex)
      of.addEventListener("change", () => { pane.split.of = of.value; this.changed() })

      const direction = this.el("select")
      direction.setAttribute("aria-label", `Pane ${label} direction`)
      for (const [ value, text ] of [ [ "right", "to the right" ], [ "down", "below" ] ]) {
        direction.append(this.option(value, text, pane.split.direction === value))
      }
      direction.addEventListener("change", () => { pane.split.direction = direction.value; this.changed() })

      const ratio = this.input(pane.split.ratio ?? "", "½", (value) => { pane.split.ratio = value; this.changed() })
      ratio.type = "number"
      ratio.min = "0.1"
      ratio.max = "0.9"
      ratio.step = "0.05"
      ratio.classList.add("layout-pane-ratio")
      ratio.setAttribute("aria-label", `Pane ${label} share kept by the split pane`)
      ratio.title = "Share of the space the split pane keeps (0.1–0.9). Blank: half."

      split.append(this.el("span", "muted", "split off"), of, direction, this.el("span", "muted", "keeping"), ratio)
      row.append(split)
    } else {
      row.append(this.el("span", "muted layout-pane-root", "Fills the tab; later panes split off it."))
    }

    return row
  }

  fillSplitChoices(select, tab, paneIndex) {
    const current = tab.panes[paneIndex].split?.of
    select.replaceChildren(
      ...tab.panes.slice(0, paneIndex).map((pane) => this.option(pane.name, pane.name || "(unnamed)", pane.name === current))
    )
  }

  refreshSplitChoices(tabIndex) {
    const tab = this.tabs[tabIndex]
    const card = this.tabsTarget.querySelector(`[data-tab-index="${tabIndex}"]`)
    card?.querySelectorAll("select[data-split-of]").forEach((select) => {
      this.fillSplitChoices(select, tab, Number(select.dataset.splitOf))
    })
  }

  // A to-scale sketch of the tab: every split halves (or `ratio`s) the pane
  // it splits, exactly as herdr's pane.split does, in list order.
  renderPreview(tabIndex) {
    const preview = this.tabsTarget.querySelector(`[data-preview-for="${tabIndex}"]`)
    if (!preview) return
    const rects = {}
    const boxes = []
    this.tabs[tabIndex].panes.forEach((pane, index) => {
      if (index === 0) {
        rects[pane.name] = { x: 0, y: 0, w: 1, h: 1 }
      } else {
        const target = rects[pane.split?.of]
        if (!target) return
        const ratio = Math.min(Math.max(parseFloat(pane.split.ratio) || 0.5, 0.1), 0.9)
        if (pane.split.direction === "down") {
          rects[pane.name] = { x: target.x, y: target.y + target.h * ratio, w: target.w, h: target.h * (1 - ratio) }
          target.h *= ratio
        } else {
          rects[pane.name] = { x: target.x + target.w * ratio, y: target.y, w: target.w * (1 - ratio), h: target.h }
          target.w *= ratio
        }
      }
      boxes.push(pane)
    })
    preview.replaceChildren(...boxes.map((pane) => {
      const rect = rects[pane.name]
      const box = this.el("div", pane.name === AGENT ? "layout-preview-pane agent" : "layout-preview-pane", pane.name)
      Object.assign(box.style, {
        left: `${rect.x * 100}%`, top: `${rect.y * 100}%`, width: `${rect.w * 100}%`, height: `${rect.h * 100}%`
      })
      return box
    }))
  }

  // --- helpers ---

  uniqueName(base) {
    const taken = new Set(this.tabs.flatMap((tab) => tab.panes.map((pane) => pane.name)))
    for (let n = 1; ; n++) {
      const name = n === 1 && base !== "pane" ? base : `${base}-${n}`
      if (!taken.has(name)) return name
    }
  }

  el(tag, className, text) {
    const element = document.createElement(tag)
    if (className) element.className = className
    if (text !== undefined) element.textContent = text
    return element
  }

  input(value, placeholder, onInput) {
    const input = this.el("input")
    input.type = "text"
    input.value = value
    input.placeholder = placeholder
    input.addEventListener("input", () => onInput(input.value))
    return input
  }

  option(value, text, selected) {
    const option = this.el("option", null, text)
    option.value = value
    option.selected = selected
    return option
  }

  button(text, onClick, label, disabled = false, variant = null) {
    const button = this.el("button", variant ? `btn ${variant}` : "btn", text)
    button.type = "button"
    button.disabled = disabled
    if (label) button.setAttribute("aria-label", label)
    button.addEventListener("click", onClick)
    return button
  }
}
