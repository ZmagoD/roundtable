import test from "node:test"
import assert from "node:assert/strict"
import {suggestions, Composer} from "../js/composer.mjs"

const commands = [
  {name: "clear-history", usage: "", description: "Confirm before clearing", choices: []},
  {name: "quota-retry", usage: "<agent> on|off", description: "Resume after quota", choices: [["ada", "bob"], ["on", "off"]]},
  {name: "head", usage: "<agent|off>", description: "Primary contact", choices: [["ada", "bob", "off"]]}
]
const suggest = (text, caret = text.length, end = caret) => suggestions(text, caret, end, commands, ["all", "ada", "bob"])

test("slash commands filter and carry descriptions", () => {
  assert.equal(suggest("/").length, 3)
  assert.equal(suggest("/cl")[0].text, "/clear-history ")
  assert.equal(suggest("/cl")[0].description, "Confirm before clearing")
  assert.deepEqual(suggest("//clear-history"), [])
  assert.deepEqual(suggest("/missing"), [])
  assert.deepEqual(suggest("talk about /cl"), [])
})

test("argument choices complete participants and on/off without submitting", () => {
  assert.deepEqual(suggest("/quota-retry ").map(s => s.label), ["ada", "bob"])
  assert.equal(suggest("/quota-retry ad")[0].text, "ada ")
  assert.deepEqual(suggest("/quota-retry ada o").map(s => s.label), ["on", "off"])
  assert.deepEqual(suggest("/quota-retry ada on "), [])
  assert.deepEqual(suggest("/clear-history "), [])
  assert.equal(suggest("/head of")[0].text, "off ")
})

test("mention completion respects caret, selection and surrounding text", () => {
  const text = "Please @ada review"
  const [match] = suggest(text, 10)
  assert.equal(text.slice(0, match.start) + match.text + text.slice(match.end), "Please @ada  review")
  assert.deepEqual(suggest("contact user@ad"), [])
  assert.deepEqual(suggest("@ad", 1, 3), [])
  assert.equal(suggest("@AD")[0].text, "@ada ")
})

test("Enter and Tab accept a suggestion; a later Enter submits", () => {
  for (const key of ["Enter", "Tab"]) {
    let accepted = null
    let submitted = false
    const match = suggest("/cl")[0]
    const hook = {menu: {hidden: false}, matches: [match], selected: 0,
      accept: value => { accepted = value }, el: {requestSubmit: () => { submitted = true }}}
    Composer.onKeyDown.call(hook, {key, preventDefault() {}})
    assert.equal(accepted, match)
    assert.equal(submitted, false)
    hook.menu.hidden = true
    Composer.onKeyDown.call(hook, {key: "Enter", preventDefault() {}})
    assert.equal(submitted, true)
  }
})

test("arrows navigate, Escape closes, and IME and Shift+Enter are left alone", () => {
  let refreshed = false
  let closed = false
  const hook = {menu: {hidden: false}, matches: suggest("/"), selected: 0,
    refresh: () => { refreshed = true }, close: () => { closed = true },
    el: {requestSubmit: () => assert.fail("must not submit")}}
  Composer.onKeyDown.call(hook, {key: "ArrowUp", preventDefault() {}})
  assert.equal(hook.selected, 2)
  assert.ok(refreshed)
  Composer.onKeyDown.call(hook, {key: "Escape", preventDefault() {}, stopPropagation() {}})
  assert.ok(closed)
  Composer.onKeyDown.call(hook, {key: "Enter", shiftKey: true})
  Composer.onKeyDown.call(hook, {key: "Enter", isComposing: true})
})
