import QtQuick

// A chat reply rendered as Markdown that stays inside its own width.
//
// One Markdown Text cannot do that: Qt sets fenced code in the system fixed font at that font's own
// size, on lines that never wrap, so code runs past the bubble. The reply is split into blocks
// instead: prose stays Markdown and fenced code becomes wrapped plain text. The blocks live in a
// ListModel where only the changed ones are replaced, so a reply that is still streaming lays out
// only its last block again.
Column {
  id: body

  property string markdown: ""
  property color color: "white"
  property color linkColor: "#8ab4f8"
  property color codeBackground: Qt.rgba(1, 1, 1, 0.08)
  property string fontFamily: "monospace"
  property int pixelSize: 11
  property real radius: 0
  // Width the reply needs to show without wrapping, so a bubble can hug a short reply. Infinity
  // once any block is long enough to wrap anyway: measuring that would cost a second layout.
  property real naturalWidth: 0

  spacing: Math.round(pixelSize * 0.6)

  // Blocks are built once the body's own font and colours are set; built earlier, each block would
  // be laid out again as those arrive.
  property bool ready: false
  onMarkdownChanged: if (ready) sync()
  Component.onCompleted: {
    ready = true
    sync()
  }

  // Prose and fenced code, in order. A fence left open runs to the end, as CommonMark has it, so
  // code that is still arriving already shows as code. Long prose is cut where a new top-level block
  // starts: a long reply would otherwise be parsed and laid out from the top on every streamed chunk.
  function blocksOf(text) {
    var out = [], prose = [], size = 0, code = null, fence = "", indent = 0
    var lines = String(text).split("\n")
    // A link reference ("[1]: https://...") is resolved across the whole document, so keep it whole.
    var whole = /^ {0,3}\[[^\]\n]+\]:\s*\S/m.test(text)
    // After a blank line, an unindented line that is not a list item cannot continue the block above.
    function startsBlock(line) {
      return /^\S/.test(line) && !/^([-+*]|\d{1,9}[.)])(\s|$)/.test(line)
    }
    function endProse() {
      var joined = prose.join("\n").replace(/^\n+|\s+$/g, "")
      if (joined !== "") out.push({ kind: "prose", content: joined })
      prose = []
      size = 0
    }
    function endCode() {
      var joined = code.join("\n").replace(/\s+$/, "")
      if (joined !== "") out.push({ kind: "code", content: joined })
      code = null
    }
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (code === null) {
        var open = /^(\s*)(`{3,}|~{3,})[^`]*$/.exec(line)
        if (open) {
          endProse()
          indent = open[1].length
          fence = open[2]
          code = []
        } else {
          // Not below 600 characters, though: every block is a text document of its own.
          if (!whole && size >= 600 && prose[prose.length - 1].trim() === "" && startsBlock(line)) endProse()
          prose.push(line)
          size += line.length + 1
        }
      } else if (line.trim().indexOf(fence) === 0 && line.trim().replace(/[`~]/g, "") === "") {
        endCode()
      } else {
        // A fence nested in a list is indented with it; drop that much from each code line.
        var lead = /^\s*/.exec(line)[0].length
        code.push(line.slice(Math.min(lead, indent)))
      }
    }
    if (code !== null) endCode()
    else endProse()
    return out
  }

  // Text and code spans (`code`, ``co`de``) of one prose block, alternating; a span stays on its line.
  function spansOf(prose) {
    var parts = [], start = 0, i = prose.indexOf("`")
    while (i >= 0) {
      var j = i
      while (prose[j] === "`") j++
      var ticks = j - i, close = -1, k = j
      var lineEnd = prose.indexOf("\n", j)
      if (lineEnd < 0) lineEnd = prose.length
      if (i === 0 || prose[i - 1] !== "\\") {
        while ((k = prose.indexOf("`", k)) >= 0 && k < lineEnd) {
          var end = k
          while (prose[end] === "`") end++
          if (end - k === ticks) { close = k; break }
          k = end
        }
      }
      if (close < 0) { i = prose.indexOf("`", j); continue }
      parts.push(prose.slice(start, i), prose.slice(j, close))
      start = close + ticks
      i = prose.indexOf("`", start)
    }
    parts.push(prose.slice(start))
    return parts
  }

  // Qt ignores the Text's palette and font inside Markdown: links come out dark blue and code spans
  // in the system fixed font at its own size. Inline HTML is kept as written, so both are rewritten
  // as styled HTML.
  function decorate(prose) {
    var link = String(linkColor), tint = String(codeBackground)
    function anchor(url, label) {
      return "<a href=\"" + url.replace(/"/g, "%22") + "\"><span style=\"color:" + link + "\">" + label + "</span></a>"
    }
    function literal(code) {
      return code.replace(/[^0-9A-Za-z \u0080-\uffff]/g, function(c) { return "&#" + c.charCodeAt(0) + ";" })
    }
    var parts = spansOf(prose)
    for (var i = 0; i < parts.length; i++) {
      if (i % 2 === 1) {
        parts[i] = "<span style=\"background-color:" + tint + "\">" + literal(parts[i].trim()) + "</span>"
        continue
      }
      parts[i] = parts[i]
        // An inline image would be fetched and painted at its full size, past the bubble: link to it.
        .replace(/!\[([^\]\n]*)\]\(([^)\s]+)[^)\n]*\)/g, function(m, alt, target) {
          var label = "󰋩 " + (alt || "image")
          return /^https?:\/\//.test(target) ? "[" + label + "](" + target + ")" : label
        })
        .replace(/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g, function(m, label, url) { return anchor(url, label) })
        .replace(/<(https?:\/\/[^>\s]+)>/g, function(m, url) { return anchor(url, url) })
        .replace(/(^|[\s(])(https?:\/\/[^\s<>()\]"]+[^\s<>()\]".,;:!?])/g, function(m, pre, url) { return pre + anchor(url, url) })
    }
    return parts.join("")
  }

  // A changed block is replaced, never updated. Qt takes paragraph spacing from the font a Text had
  // before its first text, so the same Markdown set a second time comes out with its gaps closed up.
  function sync() {
    var next = blocksOf(markdown)
    for (var i = 0; i < next.length; i++) {
      var shown = i < blocks.count ? blocks.get(i) : null
      if (shown && shown.kind === next[i].kind && shown.content === next[i].content) continue
      if (shown) blocks.remove(i)
      blocks.insert(i, next[i])
    }
    if (blocks.count > next.length) blocks.remove(next.length, blocks.count - next.length)
  }

  // The colours are written into the prose, so new ones mean new blocks, for the same reason.
  function rebuild() {
    if (!ready) return
    blocks.clear()
    sync()
  }
  onLinkColorChanged: rebuild()
  onCodeBackgroundChanged: rebuild()

  function measure() {
    var widest = 0
    for (var i = 0; i < repeater.count; i++) {
      var item = repeater.itemAt(i)
      if (item) widest = Math.max(widest, item.naturalWidth)
    }
    naturalWidth = widest
  }

  ListModel { id: blocks }

  Repeater {
    id: repeater
    model: blocks
    onItemAdded: body.measure()
    onItemRemoved: body.measure()

    Rectangle {
      id: block
      required property string kind
      required property string content
      readonly property bool code: kind === "code"
      readonly property real pad: code ? Math.round(body.pixelSize * 0.6) : 0
      // Reading implicitWidth or implicitHeight makes Text lay the block out a second time, unwrapped.
      readonly property real naturalWidth: content.length > 120 ? Infinity : blockText.implicitWidth + 2 * pad
      width: body.width
      implicitHeight: blockText.height + 2 * pad
      color: code ? body.codeBackground : "transparent"
      radius: body.radius
      onNaturalWidthChanged: body.measure()

      Text {
        id: blockText
        x: block.pad
        y: block.pad
        width: block.width - 2 * block.pad
        text: block.code ? block.content : body.decorate(block.content)
        textFormat: block.code ? Text.PlainText : Text.MarkdownText
        wrapMode: Text.Wrap
        color: body.color
        font.family: body.fontFamily
        font.pixelSize: body.pixelSize
        onLinkActivated: function(link) { Qt.openUrlExternally(link) }
      }
    }
  }
}
