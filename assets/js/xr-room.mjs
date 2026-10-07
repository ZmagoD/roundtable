// The room in XR: one panel per participant, arranged in a circle around the
// viewer. Nothing here needs a graphics library — WebXR plus plain WebGL is
// enough, and the project ships no new dependency for an optional view.

// Where a participant's panel sits: on a circle of this radius, facing in.
export const RADIUS = 3
export const PANEL_W = 1.4
export const PANEL_H = 0.9

// The plain position for index `i` of `count`: the first stays in front and
// the rest alternate right and left, so a small room reads as a group in
// front of you rather than a ring you stand inside.
export function place(count, i, radius = RADIUS) {
  const step = (2 * Math.PI) / Math.max(count, 1)
  const side = i === 0 ? 0 : i % 2 === 1 ? Math.ceil(i / 2) : -Math.ceil(i / 2)
  const angle = side * step
  return {
    x: Math.sin(angle) * radius,
    y: 0,
    z: -Math.cos(angle) * radius,
    angle
  }
}

// One panel per participant, the team head kept at the front and the rest in
// roster order: the same order the sidebar shows, so the two views agree.
export function panelsFor(participants) {
  const ordered = [...participants].sort((a, b) =>
    a.head === b.head ? a.id - b.id : a.head ? -1 : 1)
  const count = ordered.length
  return ordered.map((who, index) => ({
    ...who,
    position: place(count, index)
  }))
}

// One frame of the scene: a quad per participant, lit by its status colour,
// drawn onto a canvas the page also shows. A headset is another way to look
// at the room, not a separate application.
export function drawPanels(gl, panels) {
  gl.clearColor(0.05, 0.06, 0.05, 1)
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
  const program = panelProgram(gl)
  if (!program) return
  gl.useProgram(program)
  bindPanelGeometry(gl, program)
  for (const panel of panels) {
    setPanelColor(gl, program, panel.status)
    gl.uniformMatrix4fv(program.model, false, modelMatrix(panel.position))
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
  }
}

// Column-major model matrix: rotate the quad to face the centre, then move it
// to its place on the circle.
function modelMatrix({x, y, z, angle}) {
  const c = Math.cos(angle)
  const s = Math.sin(angle)
  const w = PANEL_W / 2
  const h = PANEL_H / 2
  return new Float32Array([
    c * w, 0, s * w, 0,
    0, h, 0, 0,
    -s * w, 0, c * w, 0,
    x, y, z, 1
  ])
}

function panelProgram(gl) {
  if (gl.roundtableProgram) return gl.roundtableProgram
  const vs = "attribute vec4 aPosition; uniform mat4 uModel; " +
    "void main() { gl_Position = uModel * aPosition; }"
  const fs = "precision mediump float; uniform vec4 uColor; " +
    "void main() { gl_FragColor = uColor; }"
  const compile = (type, source) => {
    const shader = gl.createShader(type)
    gl.shaderSource(shader, source)
    gl.compileShader(shader)
    return gl.getShaderParameter(shader, gl.COMPILE_STATUS) ? shader : null
  }
  const program = gl.createProgram()
  const v = compile(gl.VERTEX_SHADER, vs)
  const f = compile(gl.FRAGMENT_SHADER, fs)
  if (!v || !f) return null
  gl.attachShader(program, v)
  gl.attachShader(program, f)
  gl.linkProgram(program)
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null
  program.model = gl.getUniformLocation(program, "uModel")
  program.color = gl.getUniformLocation(program, "uColor")
  program.position = gl.getAttribLocation(program, "aPosition")
  gl.roundtableProgram = program
  return program
}

function bindPanelGeometry(gl, program) {
  if (!gl.roundtableQuad) {
    const buffer = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
    gl.bufferData(gl.ARRAY_BUFFER,
      new Float32Array([-0.5, -0.5, 0, 1, 0.5, -0.5, 0, 1, -0.5, 0.5, 0, 1, 0.5, 0.5, 0, 1]),
      gl.STATIC_DRAW)
    gl.roundtableQuad = buffer
  }
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.roundtableQuad)
  gl.enableVertexAttribArray(program.position)
  gl.vertexAttribPointer(program.position, 4, gl.FLOAT, false, 0, 0)
}

// Running is the loud colour, approvals the warm one, and everything the
// provider is holding back stays between them; the browser draws the names,
// so the panel itself only has to say how busy its participant is.
function setPanelColor(gl, program, status) {
  const colours = {
    running: [0.32, 0.56, 0.27, 1],
    approval: [0.65, 0.33, 0.29, 1],
    queued: [0.48, 0.51, 0.68, 1],
    waiting_quota: [0.61, 0.45, 0.24, 1],
    idle: [0.29, 0.32, 0.28, 1]
  }
  gl.uniform4fv(program.color, colours[status] || colours.idle)
}

// Entering XR is the button's job to offer and the browser's to allow: this
// asks for a session and hands back one that ends itself when the headset
// does. The promise resolves {ok: false, reason} when the browser says no,
// so the page can say why the button did nothing.
export async function enterXR(canvas, participants, onEnd) {
  if (!navigator.xr) return {ok: false, reason: "unsupported"}
  if (!await navigator.xr.isSessionSupported("immersive-vr"))
    return {ok: false, reason: "unsupported"}
  const session = await navigator.xr.requestSession("immersive-vr")
  const gl = canvas.getContext("webgl", {xrCompatible: true})
  const panels = panelsFor(participants)
  session.updateRenderState({baseLayer: new XRWebGLLayer(session, gl)})
  const referenceSpace = await session.requestReferenceSpace("local-floor")

  const render = (_time, frame) => {
    const pose = frame.getViewerPose(referenceSpace)
    if (pose) {
      const layer = session.renderState.baseLayer
      gl.bindFramebuffer(gl.FRAMEBUFFER, layer.framebuffer)
      drawPanels(gl, panels)
    }
    session.requestAnimationFrame(render)
  }
  session.requestAnimationFrame(render)
  session.addEventListener("end", () => onEnd && onEnd())
  return {ok: true, session}
}
