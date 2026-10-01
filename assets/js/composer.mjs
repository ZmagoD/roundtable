export function suggestions(value, caret, end, commands, names) {
  if (caret !== end) return []
  const before = value.slice(0, caret)
  const command = before.match(/^\/(\S*)$/)
  if (command) {
    return commands.filter(c => c.name.startsWith(command[1].toLowerCase())).map(c => ({
      label: `/${c.name}${c.usage ? ` ${c.usage}` : ""}`,
      description: c.description,
      start: 0,
      end: caret + (value.slice(caret).match(/^[\w-]*/)?.[0].length || 0),
      text: `/${c.name} `
    }))
  }
  const args = before.match(/^\/(\S+) +(.*)$/)
  if (args) {
    const definition = commands.find(c => c.name === args[1])
    const words = args[2].split(/ +/)
    const typed = words.at(-1)
    const choices = definition?.choices[words.length - 1] || []
    return choices.filter(c => c.startsWith(typed.toLowerCase())).map(c => ({
      label: c, description: definition.description,
      start: caret - typed.length,
      end: caret + (value.slice(caret).match(/^[\w-]*/)?.[0].length || 0),
      text: `${c} `
    }))
  }
  const mention = before.match(/(^|\s)@([a-z0-9_-]*)$/i)
  if (!mention) return []
  // Each name arrives with the reading its provider last gave, shown beside it.
  return names
    .filter(n => n.name.startsWith(mention[2].toLowerCase()))
    .map(n => ({
      label: `@${n.name}`, description: "", usage: n.usage, level: n.level,
      start: caret - mention[2].length - 1,
      end: caret + (value.slice(caret).match(/^[\w-]*/)?.[0].length || 0),
      text: `@${n.name} `
    }))
}

export const Composer = {
  mounted() {
    this.input = this.el.querySelector("textarea")
    this.menu = this.el.querySelector("#mention-menu")
    this.matches = []
    this.selected = 0
    this.listeners = new AbortController()
    const options = {signal: this.listeners.signal}
    this.input.addEventListener("keydown", e => this.onKeyDown(e), options)
    this.input.addEventListener("input", () => { this.selected = 0; this.refresh() }, options)
    this.input.addEventListener("click", () => this.refresh(), options)
    this.input.addEventListener("keyup", e => {
      if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) this.refresh()
    }, options)
    this.input.addEventListener("blur", () => this.close(), options)
    this.menu.addEventListener("mousedown", e => {
      const item = e.target.closest("li")
      if (item) { e.preventDefault(); this.accept(this.matches[Number(item.dataset.index)]) }
    }, options)
    this.handleEvent("sent", () => { this.close(); this.input.value = ""; this.input.focus() })
  },

  destroyed() { this.listeners.abort() },

  updated() {
    if (document.activeElement === this.input) this.refresh()
    else this.close()
  },

  data(name) {
    try { return JSON.parse(this.el.dataset[name] || "[]") } catch (_) { return [] }
  },

  refresh() {
    this.matches = suggestions(this.input.value, this.input.selectionStart,
      this.input.selectionEnd, this.data("commands"), this.data("mentions"))
    if (this.matches.length === 0) return this.close()
    this.selected = Math.min(this.selected, this.matches.length - 1)
    this.menu.replaceChildren(...this.matches.map((match, index) => {
      const item = document.createElement("li")
      item.id = `mention-option-${index}`
      item.dataset.index = index
      const label = document.createElement("span")
      label.textContent = match.label
      item.append(label)
      if (match.usage) {
        const usage = document.createElement("small")
        usage.className = `usage-chip${match.level === "warn" ? " usage-warn" : ""}`
        usage.textContent = match.usage
        item.append(usage)
      }
      if (match.description) {
        const description = document.createElement("small")
        description.textContent = match.description
        item.append(description)
      }
      item.setAttribute("role", "option")
      item.setAttribute("aria-selected", String(index === this.selected))
      if (index === this.selected) item.className = "selected"
      return item
    }))
    this.menu.hidden = false
    this.input.setAttribute("aria-expanded", "true")
    this.input.setAttribute("aria-activedescendant", `mention-option-${this.selected}`)
    this.menu.children[this.selected].scrollIntoView({block: "nearest"})
  },

  close() {
    this.menu.hidden = true
    this.matches = []
    this.selected = 0
    this.input.setAttribute("aria-expanded", "false")
    this.input.removeAttribute("aria-activedescendant")
  },

  accept(match) {
    if (!match) return
    this.input.value = this.input.value.slice(0, match.start) + match.text + this.input.value.slice(match.end)
    this.input.selectionStart = this.input.selectionEnd = match.start + match.text.length
    this.close()
    this.input.dispatchEvent(new Event("input", {bubbles: true}))
    this.input.focus()
  },

  onKeyDown(e) {
    if (e.isComposing) return
    const open = !this.menu.hidden && this.matches.length > 0
    if (open && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
      e.preventDefault()
      const step = e.key === "ArrowDown" ? 1 : this.matches.length - 1
      this.selected = (this.selected + step) % this.matches.length
      return this.refresh()
    }
    if (open && !e.shiftKey && (e.key === "Enter" || e.key === "Tab")) {
      e.preventDefault()
      return this.accept(this.matches[this.selected])
    }
    if (e.key === "Escape" && open) { e.preventDefault(); e.stopPropagation(); return this.close() }
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); this.el.requestSubmit() }
  }
}
