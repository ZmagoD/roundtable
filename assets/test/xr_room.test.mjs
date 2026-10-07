import test from "node:test"
import assert from "node:assert/strict"
import {place, panelsFor} from "../js/xr-room.mjs"

test("a lone participant sits in front of the viewer", () => {
  const [one] = [place(1, 0)]
  assert.equal(one.z < 0, true)
  assert.equal(one.x, 0)
})

test("the first panel stays in front and the rest alternate sides", () => {
  const front = place(3, 0)
  assert.equal(front.x, 0)
  assert.equal(front.z < 0, true)
  const right = place(3, 1)
  const left = place(3, 2)
  assert.equal(right.x > 0, true)
  assert.equal(left.x < 0, true)
})

test("the team head keeps the front spot", () => {
  const participants = [
    {id: 2, name: "builder", status: "idle", head: false},
    {id: 1, name: "head", status: "running", head: true},
    {id: 3, name: "checker", status: "queued", head: false}
  ]
  const panels = panelsFor(participants)
  assert.equal(panels[0].name, "head")
  assert.equal(panels[0].position.x, 0)
  assert.deepEqual(panels.map(p => p.name).sort(), ["builder", "checker", "head"])
})

test("every participant gets a panel", () => {
  const panels = panelsFor([{id: 1, name: "a"}, {id: 2, name: "b"}])
  assert.equal(panels.length, 2)
})
