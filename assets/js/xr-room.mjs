// The room in XR: one panel per participant, arranged in a circle around the
// viewer. Nothing here needs a graphics library — WebXR plus plain WebGL is
// enough, and the project ships no new dependency for an optional view.

// Where a participant's panel sits: on a circle of this radius, facing in.
export const RADIUS = 3
export const PANEL_W = 1.4
export const PANEL_H = 0.9

// The plain position for index `i` of `count`: the first stays in front and
// the rest alternate right and left, within a spread the outermost panel
// never leaves — an even share of a small circle would put someone behind
// your back, so a crowded room compresses toward the front instead. The
// 80-degree cap keeps every panel in front (cosine stays positive), however
// many people are in the room.
export function place(count, i, radius = RADIUS) {
  const others = Math.max(count - 1, 1)
  const outermost = Math.ceil(others / 2)
  const step = Math.min((2 * Math.PI) / Math.max(count, 1), (4 * Math.PI / 9) / outermost)
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

// Column-major 4x4 product, the only matrix algebra the view needs.
export function multiply(a, b) {
  const out = new Float32Array(16)
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      out[c * 4 + r] =
        a[r] * b[c * 4] +
        a[4 + r] * b[c * 4 + 1] +
        a[8 + r] * b[c * 4 + 2] +
        a[12 + r] * b[c * 4 + 3]
    }
  }
  return out
}

// Column-major model matrix: scale the unit quad to panel size, rotate it to
// face the centre of the circle, then move it to its place.
export function modelMatrix({x, y, z, angle}) {
  const c = Math.cos(angle)
  const s = Math.sin(angle)
  return new Float32Array([
    c * PANEL_W, 0, s * PANEL_W, 0,
    0, PANEL_H, 0, 0,
    -s, 0, c, 0,
    x, y, z, 1
  ])
}

// One frame of the scene, once per eye: a quad per participant, lit by its
// status colour, projected the way this eye sees the room. A headset is
// another way to look at the room, not a separate application.
export function drawPanels(gl, panels, layer, pose) {
  gl.clearColor(0.05, 0.06, 0.05, 1)
  const program = panelProgram(gl)
  if (!program) return
  gl.useProgram(program)
  bindPanelGeometry(gl, program)

  for (const view of pose.views) {
    const viewport = layer.getViewport(view)
    gl.viewport(viewport.x, viewport.y, viewport.width, viewport.height)
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
    const eye = multiply(view.projectionMatrix, view.transform.inverse.matrix)
    for (const panel of panels) {
      setPanelColor(gl, program, panel.status)
      const mvp = multiply(eye, modelMatrix(panel.position))
      gl.uniformMatrix4fv(program.model, false, mvp)
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
    }
  }
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
      gl.enable(gl.DEPTH_TEST)
      drawPanels(gl, panels, layer, pose)
    }
    session.requestAnimationFrame(render)
  }
  session.requestAnimationFrame(render)
  session.addEventListener("end", () => onEnd && onEnd())
  return {ok: true, session}
}
