// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/roundtable"
import topbar from "../vendor/topbar"
import {Terminal} from "../vendor/xterm"
import {FitAddon} from "../vendor/xterm-fit"

// Theme is applied before the socket connects so the page never flashes the
// wrong one. "system" is the absence of an override, not a third palette.
const applyTheme = (choice) => {
  const root = document.documentElement
  if (choice === "light" || choice === "dark") {
    root.setAttribute("data-theme", choice)
  } else {
    root.removeAttribute("data-theme")
  }
  document.querySelectorAll("[data-theme-choice]").forEach(button => {
    button.setAttribute("aria-pressed", String(button.dataset.themeChoice === (choice || "system")))
  })
}

let storedTheme = null
try { storedTheme = localStorage.getItem("roundtable-theme") } catch (_) {}
applyTheme(storedTheme)

window.addEventListener("click", event => {
  const button = event.target.closest("[data-theme-choice]")
  if (!button) return
  const choice = button.dataset.themeChoice
  try { localStorage.setItem("roundtable-theme", choice) } catch (_) {}
  applyTheme(choice)
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks,
    // A real terminal emulator: the server has a pty, this draws what it says
    // and sends back what is typed. Bytes both ways are base64 because the
    // socket carries JSON and terminal traffic is arbitrary bytes.
    Terminal: {
      mounted() {
        const style = getComputedStyle(document.documentElement)
        this.term = new Terminal({
          fontSize: 12,
          fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
          cursorBlink: true,
          theme: {
            background: style.getPropertyValue("--terminal-bg").trim() || "#12150f",
            foreground: style.getPropertyValue("--terminal-fg").trim() || "#d7dfd0"
          }
        })
        this.fit = new FitAddon()
        this.term.loadAddon(this.fit)
        this.term.open(this.el)
        this.term.focus()

        const encode = (text) => btoa(String.fromCharCode(...new TextEncoder().encode(text)))
        this.term.onData(data => this.pushEvent("terminal-input", {data: encode(data)}))

        const sync = () => {
          this.fit.fit()
          this.pushEvent("terminal-resize", {rows: this.term.rows, cols: this.term.cols})
        }
        this.sync = sync
        // The pty only learns the size when told, and the browser can change it
        // at any moment.
        this.observer = new ResizeObserver(() => sync())
        this.observer.observe(this.el)
        requestAnimationFrame(sync)

        this.handleEvent("terminal-output", ({data}) => {
          const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0))
          this.term.write(bytes)
        })
        this.handleEvent("terminal-closed", () => {
          this.term.write("\r\n\x1b[2mThe shell exited. Close and open the terminal to start another.\x1b[0m\r\n")
        })
      },
      destroyed() {
        if (this.observer) this.observer.disconnect()
        if (this.term) this.term.dispose()
      }
    },
    Conversation: {
      mounted() { this.el.scrollTop = this.el.scrollHeight; this.follow = true; this.el.addEventListener("scroll", () => { this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 100 }) },
      updated() { if (this.follow) this.el.scrollTop = this.el.scrollHeight }
    },
    // Enter sends, Shift+Enter makes a newline, and "@" offers the people in
    // the room. Mentions are what start a turn, so they should not have to be
    // typed from memory.
    Composer: {
      mounted() {
        this.input = this.el.querySelector("textarea")
        this.menu = document.createElement("ul")
        this.menu.className = "mention-menu"
        this.menu.hidden = true
        this.el.appendChild(this.menu)
        this.matches = []
        this.selected = 0

        this.input.addEventListener("keydown", e => this.onKeyDown(e))
        this.input.addEventListener("input", () => this.refresh())
        this.input.addEventListener("blur", () => setTimeout(() => this.close(), 120))
        this.menu.addEventListener("mousedown", e => {
          const item = e.target.closest("li")
          if (item) { e.preventDefault(); this.accept(item.dataset.name) }
        })

        this.handleEvent("sent", () => { this.close(); this.input.value = ""; this.input.focus() })
      },

      names() {
        try { return JSON.parse(this.el.dataset.mentions || "[]") } catch (_) { return [] }
      },

      // The "@word" the caret is sitting in, if any.
      token() {
        const upto = this.input.value.slice(0, this.input.selectionStart)
        const match = upto.match(/(^|\s)@([a-z0-9_-]*)$/i)
        return match ? match[2] : null
      },

      refresh() {
        const typed = this.token()
        if (typed === null) return this.close()

        this.matches = this.names().filter(n => n.startsWith(typed.toLowerCase()))
        if (this.matches.length === 0) return this.close()

        this.selected = Math.min(this.selected, this.matches.length - 1)
        this.menu.innerHTML = this.matches
          .map((n, i) => `<li data-name="${n}"${i === this.selected ? ' class="selected"' : ""}>@${n}</li>`)
          .join("")
        this.menu.hidden = false
      },

      close() { this.menu.hidden = true; this.matches = []; this.selected = 0 },

      accept(name) {
        const caret = this.input.selectionStart
        const before = this.input.value.slice(0, caret).replace(/@([a-z0-9_-]*)$/i, `@${name} `)
        this.input.value = before + this.input.value.slice(caret)
        this.input.selectionStart = this.input.selectionEnd = before.length
        this.close()
        // LiveView tracks the field, so tell it what changed.
        this.input.dispatchEvent(new Event("input", {bubbles: true}))
        this.input.focus()
      },

      onKeyDown(e) {
        const open = !this.menu.hidden && this.matches.length > 0

        if (open && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
          e.preventDefault()
          const step = e.key === "ArrowDown" ? 1 : this.matches.length - 1
          this.selected = (this.selected + step) % this.matches.length
          return this.refresh()
        }

        if (open && (e.key === "Enter" || e.key === "Tab")) {
          e.preventDefault()
          return this.accept(this.matches[this.selected])
        }

        if (e.key === "Escape") return this.close()

        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          this.el.requestSubmit()
        }
      }
    }
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

