import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "puri.hermes"
  ipcTarget: "puri.hermes"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string helperPath: Qt.resolvedUrl("hermes-remote.ts").toString().replace("file://", "")

  property bool connected: false
  property string statusLine: "Connecting…"
  property string serverHost: ""
  // Edit and an open group room are modes of their own: they take the chat's place instead of squeezing it.
  readonly property bool drawerTakesOver: editing || (showingGroups && openRoom !== "")
  property string lastError: ""
  property var profiles: []
  property string selected: "default"
  property var transcripts: ({})
  property var busyProfiles: ({})
  property var approval: null
  property var clarify: null
  property int clarifyIndex: 0
  property bool pickingModel: false
  property var loadedProfiles: ({})
  property var pendingByProfile: ({})
  property var pendingFilesByProfile: ({})
  property var receivedFiles: []
  property var clearingProfiles: ({})
  property var queuedSendByProfile: ({})
  property bool attaching: false
  property bool attachOpen: false
  property bool creating: false
  property string armedDelete: ""
  property double armedAt: 0
  property int revision: 0
  property var activityByProfile: ({})
  property var todosByProfile: ({})
  property var unreadProfiles: ({})
  // Server notices (credits, slow start, rate limit / fallback) keyed like Hermes Desktop toasts.
  property var notices: ({})
  // Delegated children per bot: {profile: {subagentId: {goal, tool, count, done}}}.
  property var subagentsByProfile: ({})
  property bool recording: false
  property bool speaking: false
  property string lastSpeech: ""
  property string lastTemplate: ""
  function toggleDictation() {
    sendCommand(recording ? { cmd: "dictate.stop", profile: selected } : { cmd: "dictate.start" })
  }
  function speakText(text) {
    if (speaking) { sendCommand({ cmd: "speak.stop" }); speaking = false; return }
    sendCommand({ cmd: "speak", profile: selected, text: displayText(text), play: true })
  }
  function runningSubagents(profile) {
    var map = subagentsByProfile[profile] || {}
    var out = []
    for (var id in map) if (!map[id].done) out.push(map[id])
    return out
  }
  readonly property var noticeList: {
    revision
    var list = []
    for (var k in notices) list.push(notices[k])
    return list.sort(function(a, b) { return b.at - a.at }).slice(0, 3)
  }
  function dismissNotice(key) {
    if (notices[key] === undefined) return
    delete notices[key]
    revision++
  }
  property var lastSentByProfile: ({})
  function toggleSearch() {
    searching = !searching
    if (searching) Qt.callLater(function() { searchField.forceActiveFocus() })
    else { searchText = ""; searchField.text = ""; input.forceActiveFocus() }
  }
  function selectNth(n) {
    if (n < rosterProfiles.length) selected = rosterProfiles[n].name
  }
  function recallLastSent() {
    var last = lastSentByProfile[selected]
    if (input.text !== "" || !last) return
    input.text = last
    input.cursorPosition = input.length
  }
  property bool searching: false
  // Text of a transcript row the next message replies to (right-click a bubble); sent as a > quote.
  property string quoteText: ""
  function quoteRow(m) {
    if (!m || m.role === "tool") return
    quoteText = displayText(m.text).slice(0, 400)
    Qt.callLater(function() { input.forceActiveFocus() })
  }
  property string searchText: ""
  // The transcript filtered by the Search field (case-insensitive substring); unfiltered when empty.
  readonly property var shownMessages: {
    revision
    var q = searchText.trim().toLowerCase()
    if (q === "") return messages
    return messages.filter(function(m) { return String(m.text || "").toLowerCase().indexOf(q) >= 0 })
  }
  // The chat shows chatModel, which mirrors shownMessages one row at a time. With the array itself as
  // the model, every streamed chunk rebuilt every bubble and parsed its Markdown again, which froze
  // the shell for as long as a reply took.
  ListModel { id: chatModel }
  property var chatRows: []
  onShownMessagesChanged: syncChat()
  function syncChat() {
    var next = shownMessages, prev = chatRows
    var head = 0
    while (head < prev.length && head < next.length && prev[head] === next[head]) head++
    var tail = 0
    while (tail < prev.length - head && tail < next.length - head
           && prev[prev.length - 1 - tail] === next[next.length - 1 - tail]) tail++
    // Only the rows between the unchanged head and tail differ: rewrite those that stay, then drop
    // or add the rest.
    var was = prev.length - head - tail, now = next.length - head - tail, i
    for (i = 0; i < Math.min(was, now); i++) chatModel.setProperty(head + i, "row", JSON.stringify(next[head + i]))
    if (was > now) chatModel.remove(head + now, was - now)
    for (i = was; i < now; i++) chatModel.insert(head + i, { row: JSON.stringify(next[head + i]) })
    chatRows = next
  }
  property var usageByProfile: ({})
  readonly property var selectedTodos: { revision; return todosByProfile[selected] || [] }
  property var cronRunning: ({})
  property var historyShown: ({})
  property var sessionList: []
  property bool showingSessions: false
  property double nowMs: Date.now()
  property var screenByProfile: ({})
  property string screenBase: ""
  property bool showingRoutines: false
  // Group chats (hosted rooms). The helper polls only the open room's log.
  property bool showingGroups: false
  property var groupRooms: []
  property string openRoom: ""
  property var roomRows: []
  property bool roomWorking: false
  // Driver pending actions of the open room: member approvals and turns that need an explicit retry.
  property var roomActions: []
  property var roomSeenRequests: ({})
  // The thread a room reply continues ({thread, who, text}), and whether the room name is being edited.
  property var roomReply: null
  // Rooms with member messages the user has not seen in the panel (room id -> true).
  property var groupUnread: ({})
  property bool renamingRoom: false
  property string roomError: ""
  property var newGroupMembers: ({})
  property string armedDisband: ""
  readonly property var openRoomInfo: {
    for (var i = 0; i < groupRooms.length; i++) if (groupRooms[i].id === openRoom) return groupRooms[i]
    return null
  }
  property var routinesByProfile: ({})
  property var routineRunsById: ({})
  property string routineRunsShown: ""
  property string armedRoutine: ""
  property double armedRoutineAt: 0
  property bool editing: false
  property var profileInfo: ({})
  property bool showHidden: false
  property var skillsByProfile: ({})
  property string composerText: ""
  property bool skillsDismissed: false
  property int skillIndex: 0
  readonly property var selectedSkills: { revision; return skillsByProfile[selected] || [] }
  // "/prefix" with no space yet: up to 6 enabled skills whose name starts with the prefix.
  readonly property var skillMatches: {
    var t = composerText
    if (skillsDismissed || t.charAt(0) !== "/" || /\s/.test(t)) return []
    var prefix = t.slice(1).toLowerCase()
    return selectedSkills.filter(function(s) {
      return s.enabled !== false && s.name.toLowerCase().indexOf(prefix) === 0
    }).slice(0, 6)
  }

  // Named roster sections. The helper keeps them in ~/.hermes/bot-sections.json, the hermes-bot-kit
  // format, so Hermes Desktop with that kit shows the same layout.
  property var sectionOrder: []
  property var sectionByBot: ({})
  function sectionOf(name) { return sectionByBot[String(name).toLowerCase()] || "" }
  readonly property string selectedSection: sectionOf(selected)
  function setSection(name) {
    lastError = ""
    sendCommand({ cmd: "profile.section", profile: selected, section: String(name).trim() })
  }

  // The roster as drawn: one group per section in order, then the bots in none. Pinned bots lead
  // each group; hidden bots only with "Show hidden".
  readonly property var rosterGroups: {
    var shown = profiles.filter(function(p) { return showHidden || !p.hidden })
    var ordered = shown.filter(function(p) { return p.pinned }).concat(shown.filter(function(p) { return !p.pinned }))
    var groups = sectionOrder.map(function(s) {
      return { name: s, bots: ordered.filter(function(p) { return root.sectionOf(p.name) === s }) }
    }).filter(function(g) { return g.bots.length > 0 })
    var rest = ordered.filter(function(p) { return root.sectionOf(p.name) === "" })
    // The bots in no section get a heading only when there are sections above them.
    if (rest.length > 0 || groups.length === 0) groups.push({ name: groups.length > 0 ? "Unassigned" : "", bots: rest })
    return groups
  }
  readonly property var rosterProfiles: {
    var all = []
    rosterGroups.forEach(function(g) { all = all.concat(g.bots) })
    return all
  }
  readonly property int hiddenCount: profiles.filter(function(p) { return p.hidden }).length
  readonly property var selectedInfo: { revision; return profileInfo[selected] || null }

  readonly property var routines: { revision; return routinesByProfile[selected] || [] }
  readonly property bool routinesLoaded: { revision; return routinesByProfile[selected] !== undefined }

  readonly property var messages: { revision; return transcripts[selected] || [] }
  readonly property bool busy: { revision; return busyProfiles[selected] === true }
  readonly property var screenState: { revision; return screenByProfile[selected] || null }
  readonly property bool screenMine: screenState !== null && screenState.mine === true
  // Teach by demonstration: the bot being recorded, the bot whose next reply is a skill draft, and that draft.
  property string demoProfile: ""
  property string teachProfile: ""
  property var skillDraft: null
  readonly property string screenCaption: !screenState ? ""
    : !screenState.running ? "screen off"
    : screenMine ? "you have control"
    : screenState.lease && screenState.lease.holder === "human" ? "someone else has control" : "bot has control"
  readonly property bool anyBusy: {
    revision
    for (var k in busyProfiles) if (busyProfiles[k]) return true
    for (var j in cronRunning) if (cronRunning[j]) return true
    return false
  }
  readonly property string activityLine: {
    revision
    var cron = cronRunning[selected]
    var a = activityByProfile[selected]
    if (busy) {
      var secs = Math.max(0, Math.round((nowMs - (a ? a.since : nowMs)) / 1000))
      var label = !a ? "working…" : a.text === "thinking" ? "thinking…" : a.text === "writing" ? "writing…"
        : a.text.indexOf("❓") === 0 ? a.text : "⚙ " + a.text
      var subs = runningSubagents(selected)
      return label + " · " + secs + "s" + (subs.length > 0 ? "  ·  🔀 " + subs.length + " delegated" + (subs[0].tool ? ": " + subs[0].tool : "") : "")
    }
    // delegate_task runs in the background, so children can outlive the parent's turn.
    var running = runningSubagents(selected)
    if (running.length > 0) return "🔀 " + running.length + " delegated task" + (running.length > 1 ? "s" : "") + " running" + (running[0].tool ? ": " + running[0].tool : "")
    return cron ? "⏱ scheduled job running: " + cron : ""
  }
  readonly property bool waitingOnUser: clarify !== null || approval !== null
  readonly property string waitingProfile: clarify ? profileForSession(clarify.session)
    : approval ? profileForSession(approval.session) : ""
  readonly property var selectedProfile: {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].name === selected) return profiles[i]
    return null
  }
  readonly property var clarifyQuestion: clarify && clarify.questions ? clarify.questions[clarifyIndex] || null : null
  readonly property var modelPresets: ["auto/best-coding", "auto/best-fast", "auto/best-reasoning", "auto/cheap"]

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function notify(title, body, profile, urgency) {
    // Something happened on a bot the user is not looking at: mark it unread in the roster.
    if (profile && profile !== selected && !unreadProfiles[profile]) {
      unreadProfiles[profile] = true
      revision++
    }
    // Every panel instance receives the shared daemon's events; only the primary one toasts.
    if (!primaryClient) return
    if (opened && profile === selected) return
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Hermes Bots", "-g", "󰚩", "-u", urgency || "normal",
      title, String(body || "").slice(0, 240), "--exec", "omarchy-shell", "puri.hermes", "show", profile || selected])
  }

  // Clicking a room toast opens the panel on that room.
  function notifyRoom(room, title, body, urgency) {
    if (!primaryClient) return
    if (opened && showingGroups && openRoom === room) return
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Hermes Bots", "-g", "󰚩", "-u", urgency || "normal",
      title, String(body || "").slice(0, 240), "--exec", "omarchy-shell", "puri.hermes", "showGroup", room])
  }

  function setActivity(profile, text) {
    var prev = activityByProfile[profile]
    activityByProfile[profile] = { text: text, since: prev ? prev.since : Date.now() }
    nowMs = Date.now()
    revision++
  }

  function clearActivity(profile) {
    delete activityByProfile[profile]
    revision++
  }

  function ensureLoaded(profile) {
    if (!profile || loadedProfiles[profile]) return
    loadedProfiles[profile] = true
    sendCommand({ cmd: "load", profile: profile })
  }

  onSelectedChanged: {
    searching = false
    searchText = ""
    quoteText = ""
    if (unreadProfiles[selected]) {
      delete unreadProfiles[selected]
      revision++
    }
    showingSessions = false
    routineRunsShown = ""
    armedRoutine = ""
    ensureLoaded(selected)
    refreshSkills()
    if (showingRoutines) refreshRoutines()
    if (editing) refreshProfile()
  }

  function sendCommand(obj) {
    if (!bridge.running) return
    bridge.write(JSON.stringify(obj) + "\n")
  }

  function compactTools(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var m = list[i]
      var prev = out.length > 0 ? out[out.length - 1] : null
      if (m.role === "tool" && prev && prev.role === "tool" && String(m.text).indexOf("⚙ ") === 0 && String(prev.text).indexOf("⚙ ") === 0)
        out[out.length - 1] = { role: "tool", text: prev.text + " · " + String(m.text).slice(2) }
      else out.push(m)
    }
    return out
  }

  readonly property var pendingImages: { revision; return pendingByProfile[selected] || [] }
  readonly property var pendingFiles: { revision; return pendingFilesByProfile[selected] || [] }

  // Prompts reloaded from history carry the gateway's "@image:/path" and "@file:/path" lines.
  function attachmentRefs(text) {
    return text.replace(/^@(image|file):(\S+)\s*$/gm, function(m, kind, path) {
      return (kind === "image" ? "󰋩 " : "󰈔 ") + path.split("/").pop()
    })
  }

  function displayText(text) {
    return String(text || "").split("\n").filter(function(l) { return !/^\s*MEDIA:\S+\s*$/.test(l) }).join("\n").trim()
  }

  // Theme accent, or a light blue when the theme's accent equals the text colour.
  readonly property color linkColor: Qt.colorEqual(Color.accent, foreground) ? "#8ab4f8" : Color.accent

  function addMedia(profile, remote, local, error) {
    var list = (transcripts[profile] || []).slice()
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].role === "bot" && String(list[i].text).indexOf(remote) >= 0) {
        if (error) {
          list.splice(i + 1, 0, { role: "tool", text: "image unavailable: " + remote + " (" + error + ")" })
        } else {
          var images = (list[i].images || []).slice()
          if (images.indexOf(local) < 0) images.push(local)
          list[i] = Object.assign({}, list[i], { images: images })
        }
        transcripts[profile] = list
        revision++
        return
      }
    }
  }

  function addFile(profile, remote, name, local, error) {
    receivedFiles = receivedFiles.concat([{ profile: profile, name: name, remote: remote, local: local || "", error: error || "" }]).slice(-10)
    var list = (transcripts[profile] || []).slice()
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].role === "bot" && String(list[i].text).indexOf(remote) >= 0) {
        if (error) {
          list.splice(i + 1, 0, { role: "tool", text: "file unavailable: " + remote + " (" + error + ")" })
        } else {
          var files = (list[i].files || []).filter(function(f) { return f.local !== local })
          files.push({ name: name, local: local })
          list[i] = Object.assign({}, list[i], { files: files })
        }
        transcripts[profile] = list
        revision++
        return
      }
    }
  }

  function openFile(local) { return Qt.openUrlExternally("file://" + local) }

  function pushMessage(profile, role, text, images, files) {
    flushStream()
    var list = (transcripts[profile] || []).slice()
    var row = { role: role, text: text }
    if (images && images.length > 0) row.images = images
    if (files && files.length > 0) row.files = files
    list.push(row)
    list = compactTools(list)
    transcripts[profile] = list
    revision++
  }

  function appendToLast(profile, text) {
    var list = (transcripts[profile] || []).slice()
    if (list.length === 0 || list[list.length - 1].role !== "bot") list.push({ role: "bot", text: "" })
    list[list.length - 1] = { role: "bot", text: list[list.length - 1].text + text }
    transcripts[profile] = list
    revision++
  }

  // Streamed text is shown at most every 50 ms. Tokens arrive faster than that, and each one shown
  // costs a layout of the reply's last block.
  property var streamPending: ({})
  Timer { id: streamTimer; interval: 50; onTriggered: if (root.flushStream()) restart() }
  function flushStream() {
    var pending = streamPending, shown = false
    streamPending = ({})
    for (var profile in pending) {
      appendToLast(profile, pending[profile])
      shown = true
    }
    return shown
  }

  function setBusy(profile, value) {
    busyProfiles[profile] = value
    revision++
  }

  property var sessionOwner: ({})

  function profileForSession(sid) { return sessionOwner[sid] || selected }

  function handleEvent(line) {
    var ev
    try { ev = JSON.parse(line) } catch (e) { return }
    // Whatever this is, it comes after the text already received.
    if (ev.ev !== "delta") flushStream()
    switch (ev.ev) {
    case "ready":
      loadedProfiles = ({})
      sendCommand({ cmd: "refresh" })
      ensureLoaded(selected)
      break
    case "role":
      primaryClient = ev.primary === true
      break
    case "status":
      connected = true
      lastError = ""
      profiles = ev.profiles || []
      sectionOrder = ev.sections ? ev.sections.order : []
      sectionByBot = ev.sections ? ev.sections.assign : ({})
      var names = profiles.map(function(p) { return p.name })
      for (var known in transcripts) if (names.indexOf(known) < 0 && known !== "default") forgetBot(known)
      if (names.indexOf(selected) < 0) selected = "default"
      serverHost = ev.url.replace(/^https?:\/\//, "")
      statusLine = "v" + ev.version + (ev.gatewayRunning ? "" : " · gateway off")
      break
    case "session":
      sessionOwner[ev.session] = ev.profile
      break
    case "sent":
      sessionOwner[ev.session] = ev.profile
      // A turn another panel instance started.
      if (!busyProfiles[ev.profile]) {
        setBusy(ev.profile, true)
        setActivity(ev.profile, "thinking")
      }
      break
    case "steered":
    case "queued":
      if (ev.error) {
        lastError = ev.error
        pushMessage(ev.profile, "tool", (ev.ev === "steered" ? "↪ steer failed: " : "⏳ queue failed: ") + ev.error)
      } else if (ev.status === "sent") {
        // The turn had already ended, so the text went out as a normal message.
        pushMessage(ev.profile, "you", ev.text)
        setBusy(ev.profile, true)
        setActivity(ev.profile, "thinking")
      } else {
        pushMessage(ev.profile, "you", (ev.ev === "steered" ? "↪ steer: " : "⏳ queued: ") + ev.text)
      }
      break
    case "start":
      // A turn the panel did not start: a queued message draining, or a background result
      // (delegated task, process) that Hermes hands back to the bot as a new turn.
      var starter = profileForSession(ev.session)
      if (!busyProfiles[starter]) {
        setBusy(starter, true)
        setActivity(starter, "thinking")
        pushMessage(starter, "tool", "⏳ bot continues (queued message or background result)")
      }
      break
    case "history":
      if (ev.session) sessionOwner[ev.session] = ev.profile
      if (ev.replace) {
        transcripts[ev.profile] = compactTools(tidyHistory(ev.messages))
        pendingByProfile[ev.profile] = []
        pendingFilesByProfile[ev.profile] = []
        historyShown[ev.profile] = true
        showingSessions = false
        revision++
      } else if (!historyShown[ev.profile]) {
        // Rows that arrived before the history load (a live reply, a cron report) stay after it.
        transcripts[ev.profile] = compactTools(tidyHistory(ev.messages).concat(transcripts[ev.profile] || []))
        historyShown[ev.profile] = true
        revision++
      }
      break
    case "sessions":
      if (ev.profile === selected) sessionList = ev.sessions || []
      break
    case "screen.url":
      screenBase = ev.base
      if (ev.open && primaryClient) Qt.openUrlExternally(ev.url)
      break
    case "screen":
      screenByProfile[ev.profile] = { running: ev.running, lease: ev.lease, mine: ev.mine }
      revision++
      break
    case "demo":
      if (ev.recording) {
        demoProfile = ev.profile
      } else {
        demoProfile = ""
        if (ev.steps.length === 0) lastError = "no demonstration steps were recorded"
        else if (busyProfiles[ev.profile]) lastError = "@" + ev.profile + " is busy; the demonstration was not sent"
        else {
          teachProfile = ev.profile
          sendTextForProfile(ev.profile, teachPrompt(ev.steps), [], [])
        }
      }
      break
    case "skillSaved":
      pushMessage(ev.profile, "tool", "🎓 skill saved: /" + ev.name)
      if (skillDraft && skillDraft.profile === ev.profile && skillDraft.name === ev.name) skillDraft = null
      break
    case "screen.error":
      lastError = "@" + ev.profile + " screen: " + ev.message
      break
    case "activity":
      var actor = profileForSession(ev.session)
      if (busyProfiles[actor]) setActivity(actor, ev.text)
      break
    case "usage":
      usageByProfile[profileForSession(ev.session)] = { total: ev.total, contextPercent: ev.contextPercent }
      revision++
      break
    case "notice":
      notices[ev.key] = { key: ev.key, text: String(ev.text).replace(/^[•⚠✕✗✓]\s*/, ""), level: ev.level,
        expires: ev.kind === "ttl" && ev.ttl_ms > 0 ? Date.now() + ev.ttl_ms : 0, at: Date.now() }
      revision++
      break
    case "notice_clear":
      dismissNotice(ev.key)
      break
    case "groups":
      groupRooms = ev.rooms || []
      break
    case "group.activity":
      if (!(opened && showingGroups && openRoom === ev.room)) {
        var unread = Object.assign({}, groupUnread)
        unread[ev.room] = true
        groupUnread = unread
      }
      notifyRoom(ev.room, "@" + ev.who + " in " + ev.name, ev.text, ev.mention ? "critical" : "normal")
      break
    case "group.opened":
      if (groupUnread[ev.room]) {
        var seenRooms = Object.assign({}, groupUnread)
        delete seenRooms[ev.room]
        groupUnread = seenRooms
      }
      openRoom = ev.room
      roomRows = []
      roomWorking = false
      roomActions = []
      roomError = ""
      roomReply = null
      renamingRoom = false
      break
    case "group.log":
      if (ev.room !== openRoom) break
      if (ev.rows.length > 0) roomRows = roomRows.concat(ev.rows).slice(-150)
      roomWorking = ev.working === true
      roomActions = ev.actions || []
      for (var ai = 0; ai < roomActions.length; ai++) {
        var act = roomActions[ai]
        if (act.kind !== "approval" || roomSeenRequests[act.requestId]) continue
        roomSeenRequests[act.requestId] = true
        notifyRoom(openRoom, "@" + act.member + " needs approval in " + (openRoomInfo ? openRoomInfo.name : "a group"),
          act.description || act.command, "critical")
      }
      break
    case "group.error":
      if (ev.room === "" || ev.room === openRoom) roomError = ev.message
      break
    case "group.disbanded":
      if (ev.room === openRoom) {
        openRoom = ""
        roomRows = []
        roomWorking = false
        roomError = ""
      }
      break
    case "template.exported":
      lastTemplate = ev.path
      pushMessage(ev.profile, "tool", "📦 template saved: " + ev.path + " (" + ev.skills + " skills, " + ev.routines + " routines)")
      break
    case "template.imported":
      pushMessage(ev.profile, "tool", "📦 created from template (" + ev.skills + " skills, " + ev.routines + " routines)")
      selected = ev.profile
      break
    case "dictation":
      recording = ev.recording === true
      break
    case "transcript":
      if (ev.text === "") lastError = "no speech recognised"
      else {
        input.text = input.text === "" ? ev.text : input.text + " " + ev.text
        input.cursorPosition = input.length
      }
      break
    case "speech":
      speaking = ev.playing === true
      lastSpeech = ev.local
      break
    case "speech.done":
      speaking = false
      break
    case "subagent":
      var parentBot = profileForSession(ev.session)
      var subs = subagentsByProfile[parentBot] || {}
      var sub = subs[ev.id] || { id: ev.id, goal: ev.goal, tool: "", count: 0, done: false }
      if (ev.goal) sub.goal = ev.goal
      if (ev.phase === "tool" && ev.tool) { sub.tool = ev.tool; sub.count = ev.count }
      if (ev.phase === "start") pushMessage(parentBot, "tool", "🔀 delegated: " + sub.goal)
      if (ev.phase === "done") {
        sub.done = true
        pushMessage(parentBot, "tool", "🔀 " + (ev.status || "done") + (ev.secs ? " in " + Math.round(ev.secs) + "s" : "") + " · " + sub.goal
          + (ev.summary ? " — " + ev.summary.split("\n")[0] : ""))
      }
      subs[ev.id] = sub
      subagentsByProfile[parentBot] = subs
      revision++
      break
    case "todos":
      todosByProfile[profileForSession(ev.session)] = ev.todos || []
      revision++
      break
    case "cron.running":
      cronRunning[ev.profile] = ev.running ? ev.job : ""
      revision++
      if (showingRoutines && ev.profile === selected) refreshRoutines()
      break
    case "routines":
      routinesByProfile[ev.profile] = ev.jobs || []
      revision++
      break
    case "routine":
      if (ev.action === "created" && ev.profile === selected) {
        routineNameField.text = ""
        routineScheduleField.text = ""
        routinePromptField.text = ""
      }
      if (ev.action === "delete") {
        delete routineRunsById[ev.id]
        revision++
      }
      if (ev.action === "run" && routineRunsShown === ev.id) sendCommand({ cmd: "routine.runs", profile: ev.profile, id: ev.id })
      lastError = ""
      break
    case "routine.runs":
      routineRunsById[ev.id] = ev.runs || []
      revision++
      break
    case "cron":
      var when = new Date(ev.at)
      pushMessage(ev.profile, "tool", "⏱ " + ev.job + " · " + Qt.formatTime(when, "HH:mm")
        + (ev.status && ev.status !== "ok" ? " · " + ev.status + (ev.error ? ": " + ev.error : "") : ""))
      if (ev.text) pushMessage(ev.profile, "bot", ev.text)
      if (ev.notify) notify("@" + ev.profile + " · " + ev.job, ev.text || ev.error || ev.status, ev.profile)
      if (showingRoutines && ev.profile === selected) refreshRoutines()
      break
    case "attached":
      attaching = false
      lastError = ""
      if (ev.kind === "file")
        pendingFilesByProfile[ev.profile] = (pendingFilesByProfile[ev.profile] || []).concat([{ name: ev.name, local: ev.local, ref: ev.ref }])
      else pendingByProfile[ev.profile] = (pendingByProfile[ev.profile] || []).concat([ev.local])
      revision++
      break
    case "media":
      addMedia(ev.profile, ev.remote, ev.local, ev.error)
      break
    case "file":
      addFile(ev.profile, ev.remote, ev.name, ev.local, ev.error)
      break
    case "cleared":
      delete todosByProfile[ev.profile]
      delete subagentsByProfile[ev.profile]
      var queued = queuedSendByProfile[ev.profile]
      transcripts[ev.profile] = []
      pendingByProfile[ev.profile] = []
      pendingFilesByProfile[ev.profile] = []
      busyProfiles[ev.profile] = false
      delete activityByProfile[ev.profile]
      delete clearingProfiles[ev.profile]
      delete queuedSendByProfile[ev.profile]
      revision++
      if (queued) sendTextForProfile(ev.profile, queued.text, queued.images, queued.files)
      if (showingSessions && ev.profile === selected) refreshSessions()
      break
    case "model":
      pickingModel = false
      profiles = profiles.map(function(p) { return p.name === ev.profile ? Object.assign({}, p, { model: ev.model }) : p })
      pushMessage(ev.profile, "tool", "model → " + ev.model)
      break
    case "clarify":
      clarify = ev
      clarifyIndex = 0
      var asker = profileForSession(ev.session)
      for (var qi = 0; qi < ev.questions.length; qi++) pushMessage(asker, "tool", "❓ " + ev.questions[qi].question)
      if (busyProfiles[asker]) setActivity(asker, "❓ waiting for your answer")
      notify("@" + asker + " asks", ev.questions.length > 0 ? ev.questions[0].question : "", asker, "critical")
      if (opened && asker === selected) Qt.callLater(function() { clarifyField.forceActiveFocus() })
      break
    case "request.cancel":
      var withdrawn = profileForSession(ev.session)
      if (clarify && String(clarify.requestId) === String(ev.requestId)) {
        clarify = null
        pushMessage(withdrawn, "tool", "❓ question expired" + (ev.reason ? " (" + ev.reason + ")" : ""))
      }
      if (approval && String(approval.requestId) === String(ev.requestId)) {
        approval = null
        pushMessage(withdrawn, "tool", "✔ approval expired" + (ev.reason ? " (" + ev.reason + ")" : ""))
      }
      break
    case "delta":
      var writer = profileForSession(ev.session)
      streamPending[writer] = (streamPending[writer] || "") + ev.text
      if (!streamTimer.running) {
        flushStream()
        streamTimer.start()
      }
      if (busyProfiles[writer] && (!activityByProfile[writer] || activityByProfile[writer].text !== "writing"))
        setActivity(writer, "writing")
      break
    case "tool":
      if (ev.phase === "start") pushMessage(profileForSession(ev.session), "tool", "⚙ " + ev.name + (ev.context ? " " + ev.context : ""))
      break
    case "done":
      var owner = profileForSession(ev.session)
      var list = transcripts[owner] || []
      var lastRow = list.length > 0 ? list[list.length - 1] : null
      var streamed = lastRow && lastRow.role === "bot" ? String(lastRow.text).trim() : ""
      // Hermes may complete with "" after streaming the answer; the streamed text is the reply.
      var finished = String(ev.text || "").trim() || streamed
      if (finished === "") {
        if (list.length > 0 && list[list.length - 1].role === "bot" && String(list[list.length - 1].text).trim() === "") {
          transcripts[owner] = list.slice(0, -1)
          revision++
        }
        pushMessage(owner, "tool", "■ stopped")
      } else {
        if (!streamed) pushMessage(owner, "bot", finished)
        notify("@" + owner + " replied", displayText(finished), owner)
      }
      if (teachProfile === owner) {
        teachProfile = ""
        var draft = parseSkillDraft(finished)
        if (draft) {
          draft.profile = owner
          skillDraft = draft
        } else if (finished !== "") {
          lastError = "@" + owner + " did not reply with a SKILL.md to save"
        }
      }
      setBusy(owner, false)
      clearActivity(owner)
      break
    case "approval":
      approval = ev
      if (busyProfiles[profileForSession(ev.session)]) setActivity(profileForSession(ev.session), "❓ waiting for your approval")
      notify("@" + profileForSession(ev.session) + " needs approval", ev.description || ev.command,
        profileForSession(ev.session), "critical")
      break
    case "created":
      creating = false
      duplicateField.text = ""
      selected = ev.name
      break
    case "profile":
      profileInfo[ev.profile] = { description: ev.description, soul: ev.soul, pinned: ev.pinned, hidden: ev.hidden }
      revision++
      if (editing && ev.profile === selected && !editDescField.activeFocus && !soulArea.activeFocus) {
        editDescField.text = ev.description
        soulArea.text = ev.soul
      }
      break
    case "profileSaved":
      lastError = ""
      break
    case "deleted":
      forgetBot(ev.name)
      break
    case "skills":
      skillsByProfile[ev.profile] = ev.skills || []
      revision++
      break
    case "skillShown":
      // The typed "/name" row becomes the gateway's display text; the directive itself is never shown.
      var shownIn = ev.profile || profileForSession(ev.session)
      var rows = (transcripts[shownIn] || []).slice()
      for (var r = rows.length - 1; r >= 0; r--) {
        if (rows[r].role !== "you") continue
        rows[r] = Object.assign({}, rows[r], { text: ev.display })
        transcripts[shownIn] = rows
        revision++
        break
      }
      break
    case "disconnected":
      connected = false
      statusLine = "Disconnected"
      break
    case "error":
      lastError = ev.message
      if (skillDraft && skillDraft.saving) skillDraft = Object.assign({}, skillDraft, { saving: false, error: ev.message })
      attaching = false
      var failed = ev.profile || (ev.session ? profileForSession(ev.session) : selected)
      if (clearingProfiles[failed]) {
        delete clearingProfiles[failed]
        delete queuedSendByProfile[failed]
        revision++
      }
      setBusy(failed, false)
      clearActivity(failed)
      if (ev.fatal) connected = false
      break
    }
  }

  function submit() {
    if (busy) steerText(input.text, "steer")
    else sendText(input.text)
    input.text = ""
  }

  // While the bot works, "steer" redirects the running turn and "queue" runs after it;
  // the transcript row is added when the helper confirms.
  function steerText(raw, mode) {
    var text = String(raw || "").trim()
    if (text === "") return false
    if (!busy) return sendText(text)
    sendCommand({ cmd: mode, profile: selected, text: text })
    return true
  }

  function sendText(raw) {
    var text = String(raw || "").trim()
    var images = pendingImages
    var files = pendingFiles
    if ((text === "" && images.length === 0 && files.length === 0) || busy || attaching) return false
    if (quoteText !== "" && text !== "") {
      text = quoteText.split("\n").map(function(l) { return "> " + l }).join("\n") + "\n\n" + text
      quoteText = ""
    }
    if (clearingProfiles[selected]) {
      if (queuedSendByProfile[selected]) return false
      queuedSendByProfile[selected] = { text: text, images: images, files: files }
      pendingByProfile[selected] = []
      pendingFilesByProfile[selected] = []
      revision++
      return true
    }
    return sendTextForProfile(selected, text, images, files)
  }

  // The helper prepends the pending @file: refs to the prompt; the bubble lists the files as chips.
  function sendTextForProfile(profile, text, images, files) {
    if (text === "") text = images.length > 0 ? "(image)" : "(file)"
    lastSentByProfile[profile] = text
    pushMessage(profile, "you", text, images, (files || []).map(function(f) { return { name: f.name, local: f.local } }))
    pendingByProfile[profile] = []
    pendingFilesByProfile[profile] = []
    setBusy(profile, true)
    setActivity(profile, "thinking")
    sendCommand({ cmd: "send", profile: profile, text: text })
    return true
  }

  // History, Routines, Groups, Edit, the model list and the new-bot form share the space above the
  // chat. Only one is open at a time, so the conversation is never pushed out of view.
  function closeDrawers(keep) {
    if (keep !== "sessions") showingSessions = false
    if (keep !== "routines") showingRoutines = false
    if (keep !== "groups" && showingGroups) toggleGroups()
    if (keep !== "edit") editing = false
    if (keep !== "model") pickingModel = false
    if (keep !== "create") creating = false
  }

  function toggleSessions() {
    if (showingSessions) showingSessions = false
    else refreshSessions()
  }

  function refreshSessions() {
    if (!showingSessions) closeDrawers("sessions")
    showingSessions = true
    sessionList = []
    sendCommand({ cmd: "sessions", profile: selected })
  }

  function openSession(id) {
    if (busy || !id) return false
    sendCommand({ cmd: "open", profile: selected, session: id })
    return true
  }

  function toggleRoutines() {
    if (!showingRoutines) closeDrawers("routines")
    showingRoutines = !showingRoutines
    if (showingRoutines) refreshRoutines()
  }

  function toggleGroups() {
    if (!showingGroups) closeDrawers("groups")
    showingGroups = !showingGroups
    roomError = ""
    if (showingGroups) {
      sendCommand({ cmd: "groups" })
      if (openRoom !== "") sendCommand({ cmd: "group.open", room: openRoom })
    } else if (openRoom !== "") {
      sendCommand({ cmd: "group.close" })
    }
  }

  function openGroup(id) {
    armedDisband = ""
    roomError = ""
    sendCommand({ cmd: "group.open", room: id })
  }

  function closeRoom() {
    if (openRoom !== "") sendCommand({ cmd: "group.close" })
    openRoom = ""
    roomRows = []
    roomWorking = false
    roomActions = []
    roomReply = null
    renamingRoom = false
    armedDisband = ""
    sendCommand({ cmd: "groups" })
  }

  function toggleGroupMember(name) {
    var m = Object.assign({}, newGroupMembers)
    if (m[name]) delete m[name]
    else m[name] = true
    newGroupMembers = m
  }

  function createGroup(name) {
    var title = String(name || "").trim()
    var members = Object.keys(newGroupMembers)
    if (title === "") { roomError = "name the group first"; return false }
    if (members.length < 2 || members.length > 6) { roomError = "pick 2 to 6 bots"; return false }
    roomError = ""
    sendCommand({ cmd: "group.create", name: title, members: members })
    newGroupMembers = ({})
    return true
  }

  function sendToRoom(text) {
    var body = String(text || "").trim()
    if (openRoom === "" || body === "") return false
    sendCommand({ cmd: "group.send", room: openRoom, text: body, thread: roomReply ? roomReply.thread : "" })
    roomReply = null
    return true
  }

  // Clicking a message continues its thread; a bot's message also addresses that bot.
  function replyInRoom(row) {
    if (!row || !row.thread) return false
    roomReply = { thread: row.thread, who: row.role === "bot" ? row.who : "", text: String(row.text || "") }
    if (roomReply.who !== "" && roomInput.text.indexOf("@" + roomReply.who) < 0) roomInput.text = "@" + roomReply.who + " " + roomInput.text
    roomInput.forceActiveFocus()
    return true
  }

  function renameRoom(name) {
    var title = String(name || "").trim()
    if (openRoom === "" || title === "") return false
    sendCommand({ cmd: "group.rename", room: openRoom, name: title })
    renamingRoom = false
    return true
  }

  // The card stays until the next poll shows the action resolved, so a failed answer is not hidden.
  function answerRoomApproval(action, choice) {
    sendCommand({ cmd: "group.approve", room: openRoom, member: action.member, taskId: action.taskId,
      generation: action.generation, requestId: action.requestId, choice: choice })
  }

  function retryRoomTask(taskId) {
    sendCommand({ cmd: "group.retry", room: openRoom, taskId: taskId })
  }

  function requestDisband() {
    if (armedDisband !== openRoom) { armedDisband = openRoom; return }
    sendCommand({ cmd: "group.disband", room: openRoom })
    armedDisband = ""
  }

  function refreshRoutines() {
    sendCommand({ cmd: "routines", profile: selected })
  }

  function routineCommand(action, id) {
    if (!id) return false
    lastError = ""
    sendCommand({ cmd: "routine." + action, profile: selected, id: id })
    return true
  }

  function createRoutine(name, schedule, prompt) {
    var s = String(schedule || "").trim()
    var p = String(prompt || "").trim()
    if (s === "" || p === "") return false
    lastError = ""
    sendCommand({ cmd: "routine.create", profile: selected, name: String(name || "").trim(), schedule: s, prompt: p })
    return true
  }

  function toggleRoutineRuns(id) {
    routineRunsShown = routineRunsShown === id ? "" : id
    if (routineRunsShown !== "") routineCommand("runs", id)
  }

  // Same two-click guard as bot delete.
  function requestRoutineDelete(id) {
    if (!id) return false
    if (armedRoutine !== id) {
      armedRoutine = id
      armedRoutineAt = Date.now()
      routineDisarmTimer.restart()
      return false
    }
    if (Date.now() - armedRoutineAt < 800) return false
    armedRoutine = ""
    routineDisarmTimer.stop()
    return routineCommand("delete", id)
  }

  function formatWhen(v) {
    if (v === null || v === undefined || v === "") return "—"
    var d = typeof v === "number" ? new Date(v * 1000) : new Date(v)
    return isNaN(d.getTime()) ? String(v) : Qt.formatDateTime(d, "MM-dd HH:mm")
  }

  function screenUrl(profile) {
    return screenBase ? screenBase + "/screen?profile=" + encodeURIComponent(profile) : ""
  }

  // The helper starts its loopback screen server lazily and answers with "screen.url".
  function openScreen() {
    lastError = ""
    sendCommand({ cmd: "screen.url", profile: selected, open: true })
  }

  function screenLease(op) {
    lastError = ""
    sendCommand({ cmd: op === "take" ? "screen.take" : "screen.handback", profile: selected })
  }

  // The page is where the person demonstrates; the helper records what it relays to the bot's screen.
  function startDemo() {
    openScreen()
    sendCommand({ cmd: "demo.start", profile: selected })
  }

  function stopDemo() {
    sendCommand({ cmd: "demo.stop", profile: demoProfile || selected })
  }

  function teachPrompt(steps) {
    return "I just demonstrated a task on your Bot Desktop while I had control of the screen. "
      + "My inputs, in order (screen pixel coordinates):\n"
      + steps.map(function(s, i) { return (i + 1) + ". " + s }).join("\n")
      + "\n\nTurn this into a reusable skill so you can do the task yourself with your computer tools. "
      + "Infer the goal from the steps (take a screenshot if it helps), find on-screen elements by what they show "
      + "rather than by fixed coordinates, and say what to check after each step. Reply with only the SKILL.md: "
      + "YAML front matter with name (lowercase-with-dashes) and description (one sentence of at most 60 characters, "
      + "trigger first, ending with a period), then the instructions."
  }

  // The draft is the reply's SKILL.md, fenced or not: front matter with a name, then the body.
  function parseSkillDraft(text) {
    var body = String(text || "")
    var start = body.search(/^---\s*$/m)
    if (start < 0) return null
    // Drop the closing fence only when the whole SKILL.md was wrapped in one.
    var fenced = /```[A-Za-z]*[ \t]*\n\s*$/.test(body.slice(0, start))
    body = body.slice(start).trim()
    if (fenced) body = body.replace(/\n```\s*$/, "")
    var close = body.indexOf("\n---", 3)
    var name = body.match(/^name:\s*["']?([A-Za-z0-9][A-Za-z0-9_.-]*)["']?\s*$/m)
    if (close < 0 || !name || name.index > close) return null
    return { name: name[1], content: body + "\n" }
  }

  function saveSkillDraft() {
    if (!skillDraft) return false
    sendCommand({ cmd: "skill.save", profile: skillDraft.profile, name: skillDraft.name, content: skillDraft.content })
    // Kept until the helper confirms, so a rejected draft (the server validates it) stays visible with the reason.
    skillDraft = Object.assign({}, skillDraft, { saving: true, error: "" })
    return true
  }

  function attachFrom(source) {
    if (busy || attaching) return false
    attaching = true
    lastError = ""
    var cmd = { cmd: "attach", profile: selected }
    if (source === "clipboard") cmd.clipboard = true
    else cmd.path = String(source || "").trim()
    sendCommand(cmd)
    return true
  }

  function toggleEdit() {
    if (!editing) closeDrawers("edit")
    editing = !editing
    if (editing) {
      var info = profileInfo[selected]
      editDescField.text = info ? info.description : ""
      soulArea.text = info ? info.soul : ""
      refreshProfile()
    }
  }

  function toggleModelPicker() {
    if (!pickingModel) closeDrawers("model")
    pickingModel = !pickingModel
  }

  function refreshProfile() { sendCommand({ cmd: "profile.get", profile: selected }) }

  function refreshSkills() { if (selected) sendCommand({ cmd: "skills", profile: selected }) }

  function completeSkill(i) {
    var s = skillMatches[i]
    if (!s) return
    input.text = "/" + s.name + " "
    input.cursorPosition = input.text.length
  }

  function saveSkill(rawName, content) {
    var name = String(rawName || "").trim().toLowerCase().replace(/\s+/g, "-")
    if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(name) || !content) return false
    sendCommand({ cmd: "skill.save", profile: selected, name: name, content: content })
    return true
  }

  // Minimal SKILL.md from the last thing the user asked this bot.
  function saveLastPromptAsSkill(rawName) {
    var prompt = ""
    for (var i = messages.length - 1; i >= 0 && prompt === ""; i--)
      if (messages[i].role === "you") prompt = String(messages[i].text || "").trim()
    if (prompt === "") { lastError = "no prompt to save as a skill"; return false }
    var name = String(rawName || "").trim().toLowerCase().replace(/\s+/g, "-")
    // POST /api/skills rejects a new skill whose description exceeds 60 characters
    // (Hermes SKILL_PROMPT_DESC_LIMIT, counted in code points).
    var first = Array.from(prompt.split("\n")[0].trim())
    var desc = first.length > 60 ? first.slice(0, 59).join("") + "…" : first.join("")
    var content = "---\nname: " + name + "\ndescription: " + JSON.stringify(desc) + "\n---\n\n# " + name
      + "\n\n## Instructions\n\n" + prompt + "\n"
    if (!saveSkill(name, content)) { lastError = "invalid skill name: " + rawName; return false }
    return true
  }

  function saveProfile(description, soul) {
    lastError = ""
    sendCommand({ cmd: "profile.save", profile: selected, description: String(description || "").trim(), soul: String(soul || "") })
    return true
  }

  function duplicateProfile(rawName) {
    var name = String(rawName || "").trim().toLowerCase().replace(/[^a-z0-9_-]/g, "-")
    if (name === "") return false
    lastError = ""
    sendCommand({ cmd: "profile.duplicate", profile: selected, newName: name })
    return true
  }

  function setProfileFlag(flag, value) {
    lastError = ""
    sendCommand({ cmd: flag === "pinned" ? "profile.pin" : "profile.hide", profile: selected, value: value === true })
  }

  function createBot() {
    createNamed(nameField.text, descField.text)
    nameField.text = ""
    descField.text = ""
  }

  function requestDelete(name) {
    if (!name || name === "default") return false
    if (armedDelete !== name) {
      armedDelete = name
      armedAt = Date.now()
      disarmTimer.restart()
      return false
    }
    if (Date.now() - armedAt < 800) return false
    armedDelete = ""
    disarmTimer.stop()
    sendCommand({ cmd: "delete", name: name })
    return true
  }

  property string renamingSession: ""
  property string armedSessionDelete: ""

  function sessionRename(id, title) {
    title = String(title || "").trim()
    if (!id || title === "") return false
    renamingSession = ""
    sendCommand({ cmd: "session.rename", profile: selected, id: id, title: title })
    return true
  }

  function sessionArchive(id) {
    if (!id) return false
    sendCommand({ cmd: "session.archive", profile: selected, id: id })
    return true
  }

  function sessionDelete(id) {
    if (!id) return false
    armedSessionDelete = ""
    sendCommand({ cmd: "session.delete", profile: selected, id: id })
    return true
  }

  // Same two-click guard as deleting a bot.
  function requestSessionDelete(id) {
    if (armedSessionDelete !== id) {
      armedSessionDelete = id
      armedAt = Date.now()
      disarmTimer.restart()
      return false
    }
    if (Date.now() - armedAt < 800) return false
    disarmTimer.stop()
    return sessionDelete(id)
  }

  // Stored "you" rows carry what Hermes fed the model: the cron scaffold and the expanded
  // attachments. Show what the user wrote; `full` keeps the original for click-to-expand.
  function tidyHistory(messages) {
    return (messages || []).map(function(m) {
      if (m.role !== "you") return m
      var raw = String(m.text || "")
      // Jobs with skills put the skill text before the hint, so it is not always at index 0.
      if (raw.indexOf("[IMPORTANT: You are running as a scheduled cron job") >= 0) {
        var paragraphs = raw.split(/\n\s*\n/).filter(function(p) { return p.trim() !== "" })
        return { role: "you", text: "", full: raw, scaffold: true,
          summary: paragraphs[paragraphs.length - 1].trim().replace(/\s+/g, " ") }
      }
      var cut = raw.indexOf("--- Attached Context ---")
      var lines = (cut >= 0 ? raw.slice(0, cut) : raw).split("\n")
      var files = (m.files || []).slice()
      while (lines.length > 0) {
        var ref = /^@(file|image):(.+)$/.exec(lines[0].trim())
        if (ref) files.push({ name: ref[2].trim().replace(/^["'`]|["'`]$/g, "").split("/").pop() })
        else if (lines[0].trim() !== "" || files.length === 0) break
        lines.shift()
      }
      if (cut < 0 && files.length === (m.files || []).length) return m
      var row = { role: "you", text: lines.join("\n").trim(), full: raw }
      if (files.length > 0) row.files = files
      if (m.images) row.images = m.images
      return row
    })
  }

  function forgetBot(name) {
    delete transcripts[name]
    delete busyProfiles[name]
    if (selected === name) selected = "default"
    if (armedDelete === name) armedDelete = ""
    revision++
  }

  function createNamed(rawName, description) {
    var name = String(rawName || "").trim().toLowerCase().replace(/[^a-z0-9_-]/g, "-")
    if (name === "") return false
    sendCommand({ cmd: "create", name: name, description: String(description || "").trim() })
    return true
  }

  function newChat() {
    if (busy || clearingProfiles[selected]) return false
    clearingProfiles[selected] = true
    revision++
    sendCommand({ cmd: "new", profile: selected })
    return true
  }

  function answerClarify(answer) {
    var q = clarifyQuestion
    if (!clarify || !q) return false
    sendCommand({ cmd: "clarify", requestId: clarify.requestId, answer: String(answer), questionId: q.qid })
    pushMessage(profileForSession(clarify.session), "tool", "↳ " + (String(answer) === "" ? "(skipped)" : answer))
    if (clarifyIndex + 1 < clarify.questions.length) clarifyIndex++
    else {
      if (busyProfiles[profileForSession(clarify.session)]) setActivity(profileForSession(clarify.session), "thinking")
      clarify = null
    }
    clarifyField.text = ""
    return true
  }

  function setModel(model) {
    var id = String(model || "").trim()
    if (id === "" || !selectedProfile) return false
    sendCommand({ cmd: "model", profile: selected, provider: selectedProfile.provider || "custom", model: id })
    return true
  }

  IpcHandler {
    target: "puri.hermes"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function select(name: string): string { root.selected = name; return "ok" }
    function send(text: string): string { return root.sendText(text) ? "sent" : "busy-or-empty" }
    function create(name: string, description: string): string { return root.createNamed(name, description) ? "creating" : "invalid" }
    function deleteBot(name: string): string {
      if (name === "default" || root.profiles.every(function(p) { return p.name !== name })) return "refused"
      root.sendCommand({ cmd: "delete", name: name })
      return "deleting"
    }
    function armDelete(name: string): string { root.requestDelete(name); return root.armedDelete }
    function toggleModelPicker(): string { root.toggleModelPicker(); return String(root.pickingModel) }
    function steer(text: string): string { return root.steerText(text, "steer") ? (root.busy ? "steering" : "sent") : "empty" }
    function queue(text: string): string { return root.steerText(text, "queue") ? (root.busy ? "queueing" : "sent") : "empty" }
    function stop(): string { root.sendCommand({ cmd: "interrupt", profile: root.selected }); return "interrupting" }
    function newChat(): string { return root.newChat() ? "cleared" : "busy" }
    function answer(text: string): string { return root.answerClarify(text) ? "answered" : "no-question" }
    function setModel(model: string): string { return root.setModel(model) ? "setting" : "invalid" }
    function geometry(): string {
      if (!root.opened) return "closed"
      var p = keyCatcher.mapToItem(null, 0, 0)
      return Math.round(p.x) + "," + Math.round(p.y) + " " + Math.round(keyCatcher.width) + "x" + Math.round(keyCatcher.height)
    }
    function reconnect(): string { root.reconnect(); return "reconnecting" }
    function state(): string {
      var last = root.messages.length > 0 ? root.messages[root.messages.length - 1] : null
      return JSON.stringify({ connected: root.connected, status: root.statusLine, selected: root.selected,
        profiles: root.profiles.map(function(p) { return p.name }), busy: root.busy, armedDelete: root.armedDelete,
        roster: root.rosterProfiles.map(function(p) { return p.name }), editing: root.editing,
        model: root.selectedProfile ? root.selectedProfile.model : "",
        clarify: root.clarifyQuestion, approval: root.approval ? root.approval.description || root.approval.command : null,
        pendingImages: root.pendingImages, pendingFiles: root.pendingFiles, attaching: root.attaching,
        activity: root.activityLine, showingSessions: root.showingSessions,
        todos: root.selectedTodos,
        usage: root.usageByProfile[root.selected] || null,
        messageCount: root.messages.length, last: last, transcript: root.messages.slice(-5), error: root.lastError })
    }
    function attachClipboard(): string { return root.attachFrom("clipboard") ? "attaching" : "busy" }
    function attachFile(path: string): string { return root.attachFrom(path) ? "attaching" : "busy" }
    function files(): string { return JSON.stringify(root.receivedFiles) }
    // Same path as clicking the newest chip named `name` in the selected bot's chat.
    function openFile(name: string): string {
      for (var i = root.messages.length - 1; i >= 0; i--) {
        var hit = (root.messages[i].files || []).find(function(f) { return f.name === name && f.local })
        if (hit) return root.openFile(hit.local) ? hit.local : "failed"
      }
      return "not-found"
    }
    function show(name: string): void {
      if (root.profiles.some(function(p) { return p.name === name })) root.selected = name
      root.open()
    }
    function sessions(): string { root.refreshSessions(); return "listing" }
    function listed(): string { return JSON.stringify(root.sessionList) }
    function openSession(id: string): string { return root.openSession(id) ? "opening" : "busy" }
    function sessionRename(id: string, title: string): string { return root.sessionRename(id, title) ? "renaming" : "invalid" }
    function sessionArchive(id: string): string { return root.sessionArchive(id) ? "archiving" : "invalid" }
    function sessionDelete(id: string): string { return root.sessionDelete(id) ? "deleting" : "invalid" }
    // Returns "starting" until the helper reports its server; call again for the URL.
    function screenUrl(): string {
      if (root.screenBase) return root.screenUrl(root.selected)
      root.sendCommand({ cmd: "screen.url", profile: root.selected })
      return "starting"
    }
    // Routine calls are async: these return the cached list and ask the helper for a fresh one.
    function routines(): string {
      root.refreshRoutines()
      return JSON.stringify({ profile: root.selected, loaded: root.routinesLoaded, jobs: root.routines, error: root.lastError })
    }
    // Returns the cached list for the selected bot and asks the helper for a fresh one.
    function unread(): string { return JSON.stringify(root.unreadProfiles) }
    function notices(): string { return JSON.stringify(root.noticeList) }
    function subagents(): string { return JSON.stringify(root.subagentsByProfile[root.selected] || {}) }
    function dictate(): string { root.toggleDictation(); return root.recording ? "stopping" : "recording" }
    // Test hooks: synthesise without playing, and transcribe an existing audio file.
    function speakQuiet(text: string): string { root.sendCommand({ cmd: "speak", profile: root.selected, text: text, play: false }); return "synthesising" }
    function lastSpeech(): string { return root.lastSpeech }
    function templateExport(): string { root.sendCommand({ cmd: "template.export", profile: root.selected }); return "exporting" }
    function lastTemplate(): string { return root.lastTemplate }
    function templateImport(path: string, name: string): string { root.sendCommand({ cmd: "template.import", path: path, name: name }); return "importing" }
    function groupsView(): string { root.toggleGroups(); return root.showingGroups ? "shown" : "hidden" }
    function groups(): string { return JSON.stringify(root.groupRooms) }
    function groupCreate(name: string, membersCsv: string): string {
      root.newGroupMembers = ({})
      membersCsv.split(",").forEach(function(m) { if (m.trim() !== "") root.toggleGroupMember(m.trim()) })
      return root.createGroup(name) ? "creating" : root.roomError
    }
    function groupOpen(id: string): string { root.openGroup(id); return "opening" }
    function groupSend(text: string): string { return root.sendToRoom(text) ? "sent" : "no-room-or-empty" }
    function groupUnread(): string { return JSON.stringify(Object.keys(root.groupUnread)) }
    function showGroup(room: string): void {
      root.open()
      if (!root.showingGroups) root.toggleGroups()
      root.openGroup(room)
    }
    function roomReplyLast(): string {
      var bots = root.roomRows.filter(function(r) { return r.role === "bot" })
      return bots.length > 0 && root.replyInRoom(bots[bots.length - 1]) ? "replying" : "no-bot-message"
    }
    function roomRename(name: string): string { return root.renameRoom(name) ? "renaming" : "no-room-or-empty" }
    function roomAnswer(choice: string): string {
      var a = root.roomActions.filter(function(x) { return x.kind === "approval" })[0]
      if (!a) return "no-approval"
      root.answerRoomApproval(a, choice)
      return choice
    }
    function groupDisband(id: string): string { root.sendCommand({ cmd: "group.disband", room: id }); return "disbanding" }
    function room(): string {
      return JSON.stringify({ open: root.openRoom, working: root.roomWorking, actions: root.roomActions,
        error: root.roomError, count: root.roomRows.length, rows: root.roomRows.slice(-8), reply: root.roomReply,
        name: root.openRoomInfo ? root.openRoomInfo.name : "" })
    }
    function dictateFile(path: string): string { root.sendCommand({ cmd: "dictate.file", profile: root.selected, path: path }); return "transcribing" }
    // Test hook: run a raw gateway frame (JSON) through the helper's event mapping.
    function injectFrame(json: string): string { root.sendCommand({ cmd: "inject", frame: JSON.parse(json) }); return "injected" }
    function quote(index: int): string {
      root.quoteRow(root.shownMessages[index])
      return root.quoteText
    }
    function search(text: string): string {
      root.searching = text !== ""
      root.searchText = text
      return String(root.shownMessages.length)
    }
    function skills(): string {
      root.refreshSkills()
      return JSON.stringify({ profile: root.selected, skills: root.selectedSkills })
    }
    function skillSave(name: string, content: string): string { return root.saveSkill(name, content) ? "saving" : "invalid" }
    // Test hook: sets the composer text and returns the suggestion names it now shows.
    function setComposer(text: string): string {
      input.text = text
      return JSON.stringify(root.skillMatches.map(function(s) { return s.name }))
    }
    function routineCreate(name: string, schedule: string, prompt: string): string {
      return root.createRoutine(name, schedule, prompt) ? "creating" : "invalid"
    }
    function routineRun(id: string): string { return root.routineCommand("run", id) ? "running" : "invalid" }
    function routinePause(id: string): string { return root.routineCommand("pause", id) ? "pausing" : "invalid" }
    function routineResume(id: string): string { return root.routineCommand("resume", id) ? "resuming" : "invalid" }
    function routineDelete(id: string): string { return root.routineCommand("delete", id) ? "deleting" : "invalid" }
    // Shows the Routines section (and a routine's run history) the same way its buttons do; used for captures.
    function routinesView(runsId: string): string {
      if (!root.showingRoutines) root.toggleRoutines()
      if (runsId && root.routineRunsShown !== runsId) root.toggleRoutineRuns(runsId)
      return "shown"
    }
    function routineRuns(id: string): string {
      root.routineCommand("runs", id)
      return JSON.stringify({ id: id, runs: root.routineRunsById[id] || null, error: root.lastError })
    }
    // Profile calls are async: profileGet returns the cached copy and asks the helper for a fresh one.
    function profileGet(): string {
      root.refreshProfile()
      return JSON.stringify({ profile: root.selected, loaded: root.selectedInfo !== null, info: root.selectedInfo, error: root.lastError })
    }
    function profileSave(description: string, soul: string): string { return root.saveProfile(description, soul) ? "saving" : "invalid" }
    function profileDuplicate(newName: string): string { return root.duplicateProfile(newName) ? "duplicating" : "invalid" }
    function pin(value: bool): string { root.setProfileFlag("pinned", value); return value ? "pinning" : "unpinning" }
    function hide(value: bool): string { root.setProfileFlag("hidden", value); return value ? "hiding" : "unhiding" }
    function section(name: string): string { root.setSection(name); return name.trim() === "" ? "unassigning" : "moving" }
    function sections(): string {
      return JSON.stringify({ order: root.sectionOrder, groups: root.rosterGroups.map(function(g) {
        return { name: g.name, bots: g.bots.map(function(b) { return b.name }) } }) })
    }
    function showHidden(value: bool): string { root.showHidden = value; return String(root.showHidden) }
    // Opens the Edit section the same way its button does; used for captures.
    function editView(): string { if (!root.editing) root.toggleEdit(); return "shown" }
    function screenTake(): string { root.screenLease("take"); return "taking" }
    // Test hooks: record without opening the screen page, and inspect or save the resulting draft.
    function draftState(): string { return JSON.stringify(root.approvalDraft) }
    function draftAction(action: string): string {
      if (!root.approvalDraft) return "no-draft"
      if (action === "edit") root.editDraft()
      else root.answerApproval(action === "send" ? "once" : "deny")
      return action
    }
    function demoStart(): string { root.sendCommand({ cmd: "demo.start", profile: root.selected }); return "starting" }
    function demoStop(): string { root.stopDemo(); return "stopping" }
    function demoState(): string {
      return JSON.stringify({ recording: root.demoProfile, teaching: root.teachProfile, error: root.lastError,
        draft: root.skillDraft ? { profile: root.skillDraft.profile, name: root.skillDraft.name, length: root.skillDraft.content.length,
          saving: root.skillDraft.saving === true, error: root.skillDraft.error || "" } : null })
    }
    function saveSkillDraft(): string { return root.saveSkillDraft() ? "saving" : "no-draft" }
    function screenHandback(): string { root.screenLease("handback"); return "handing-back" }
    function screenState(): string {
      var s = root.screenState
      return JSON.stringify({ profile: root.selected, url: root.screenUrl(root.selected), caption: root.screenCaption,
        running: s ? s.running : null, holder: s && s.lease ? s.lease.holder : null, mine: root.screenMine,
        error: root.lastError })
    }
  }

  // An approval raised by the outbound-review Hermes plugin (hermes-plugin/) is a message draft:
  // "To: <target>", a blank line, then the text.
  readonly property var approvalDraft: {
    if (!approval || String(approval.command).indexOf("<send_message>") !== 0) return null
    var d = String(approval.description || "")
    var m = d.match(/^To: (.*)\n\n([\s\S]*)$/)
    return m ? { target: m[1], body: m[2] } : { target: "", body: d }
  }

  // Editing is a discard plus a corrected instruction in the composer; the bot's next send is a new draft.
  function editDraft() {
    var d = approvalDraft
    if (!d) return
    answerApproval("deny")
    input.text = "Don't send that. Send this to " + (d.target || "the same recipient") + " instead:\n\n" + d.body
    input.cursorPosition = input.text.length
    input.forceActiveFocus()
  }

  function answerApproval(choice) {
    if (!approval) return
    sendCommand({ cmd: "approve", requestId: approval.requestId, choice: choice })
    pushMessage(profileForSession(approval.session), "tool", approvalDraft
      ? (choice === "deny" ? "✉ draft discarded" : "✉ draft approved, sending") : "✔ approval: " + choice)
    if (busyProfiles[profileForSession(approval.session)]) setActivity(profileForSession(approval.session), "thinking")
    approval = null
  }

  Process {
    id: bridge
    stdinEnabled: true
    command: ["sh", "-c",
      "for b in \"$HOME/.bun/bin/bun\" \"$HOME/.local/share/mise/shims/bun\" \"$(command -v bun)\"; do "
      + "[ -x \"$b\" ] && exec \"$b\" \"$0\" stdio; done; "
      + "echo '{\"ev\":\"error\",\"fatal\":true,\"message\":\"bun not found\"}'", root.helperPath]
    stdout: SplitParser { onRead: function(data) { root.handleEvent(data) } }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("puri.hermes", text.trim())
    }
    onExited: function(code) {
      root.connected = false
      if (root.reconnectPending) {
        root.reconnectPending = false
        bridge.running = true
        return
      }
      root.statusLine = "Helper exited (" + code + "), retrying"
      restartTimer.restart()
    }
  }

  Timer { id: disarmTimer; interval: 5000; onTriggered: { root.armedDelete = ""; root.armedSessionDelete = "" } }
  Timer { id: routineDisarmTimer; interval: 5000; onTriggered: root.armedRoutine = "" }
  Timer { id: restartTimer; interval: 5000; onTriggered: bridge.running = true }
  // Drops ttl notices once they expire.
  Timer {
    interval: 1000
    repeat: true
    running: root.noticeList.some(function(n) { return n.expires > 0 })
    onTriggered: {
      var now = Date.now()
      for (var k in root.notices) if (root.notices[k].expires > 0 && root.notices[k].expires <= now) root.dismissNotice(k)
    }
  }

  // The shared daemon drops its login and WebSocket and logs in again; then this panel's client is
  // restarted. Transcripts stay; 'ready' reloads the selected bot and refreshes status.
  function reconnect() {
    restartTimer.stop()
    connected = false
    lastError = ""
    statusLine = "Reconnecting…"
    if (bridge.running) {
      sendCommand({ cmd: "reconnect" })
      // Give the command time to reach the daemon before the client is stopped.
      reconnectRestartTimer.restart()
    } else {
      bridge.running = true
    }
  }
  Timer {
    id: reconnectRestartTimer
    interval: 500
    onTriggered: {
      if (bridge.running) {
        root.reconnectPending = true
        bridge.running = false
      } else {
        bridge.running = true
      }
    }
  }
  property bool reconnectPending: false
  property bool primaryClient: false
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.sendCommand({ cmd: "refresh" }) }
  Timer { interval: 1000; running: root.anyBusy; repeat: true; onTriggered: root.nowMs = Date.now() }
  Component.onCompleted: bridge.running = true

  onOpenedChanged: if (opened) {
    sendCommand({ cmd: "refresh" })
    ensureLoaded(selected)
    if (showingGroups && openRoom !== "") sendCommand({ cmd: "group.open", room: openRoom })
    Qt.callLater(function() { input.forceActiveFocus() })
  } else if (openRoom !== "") {
    // A room's log is polled only while the panel shows it.
    sendCommand({ cmd: "group.close" })
  }

    BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    active: root.anyBusy || root.waitingOnUser
    // Red when a bot is blocked on the user, accent while bots are merely working.
    activeColor: root.waitingOnUser ? root.urgent : Color.accent
    tooltipText: root.waitingOnUser ? "@" + root.waitingProfile + " is waiting for you"
      : root.anyBusy ? "Hermes bots working" : "Hermes Bots"
    onPressed: function(buttonCode) { root.toggle() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: input
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(Style.space(620), Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // renameField lives inside the History Repeater and cannot be named here.
      blocked: input.activeFocus || searchField.activeFocus || nameField.activeFocus || descField.activeFocus || root.renamingSession !== ""
        || clarifyField.activeFocus || modelField.activeFocus || attachField.activeFocus
        || routineNameField.activeFocus || routineScheduleField.activeFocus || routinePromptField.activeFocus
        || editDescField.activeFocus || soulArea.activeFocus || duplicateField.activeFocus
        || importPathField.activeFocus || importNameField.activeFocus || groupNameField.activeFocus || roomInput.activeFocus
        || roomRenameField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Window shortcuts: they fire while the panel has keyboard focus, including from the composer.
      Shortcut { sequence: "Ctrl+N"; enabled: root.opened; onActivated: root.newChat() }
      Shortcut { sequence: "Ctrl+K"; enabled: root.opened; onActivated: root.toggleSessions() }
      Shortcut { sequence: "Ctrl+F"; enabled: root.opened; onActivated: root.toggleSearch() }
      Shortcut { sequence: "Ctrl+Up"; enabled: root.opened; onActivated: root.recallLastSent() }
      Shortcut { sequence: "Alt+1"; enabled: root.opened; onActivated: root.selectNth(0) }
      Shortcut { sequence: "Alt+2"; enabled: root.opened; onActivated: root.selectNth(1) }
      Shortcut { sequence: "Alt+3"; enabled: root.opened; onActivated: root.selectNth(2) }
      Shortcut { sequence: "Alt+4"; enabled: root.opened; onActivated: root.selectNth(3) }
      Shortcut { sequence: "Alt+5"; enabled: root.opened; onActivated: root.selectNth(4) }
      Shortcut { sequence: "Alt+6"; enabled: root.opened; onActivated: root.selectNth(5) }
      Shortcut { sequence: "Alt+7"; enabled: root.opened; onActivated: root.selectNth(6) }
      Shortcut { sequence: "Alt+8"; enabled: root.opened; onActivated: root.selectNth(7) }
      Shortcut { sequence: "Alt+9"; enabled: root.opened; onActivated: root.selectNth(8) }

      Column {
        id: header
        width: parent.width
        spacing: Style.space(8)

        Item {
          width: parent.width
          implicitHeight: title.implicitHeight

          Text {
            id: title
            text: "Hermes Bots"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title !== undefined ? Style.font.title : Style.font.body * 1.3
            font.bold: true
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: title.verticalCenter
            spacing: Style.spacing.sm

            Button {
              id: reconnectButton
              visible: !root.connected
              anchors.verticalCenter: parent.verticalCenter
              text: "Reconnect"
              bordered: true
              foreground: root.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.reconnect()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: (root.connected ? "● " : "○ ") + root.statusLine
              width: Math.min(implicitWidth, parent.parent.width - title.implicitWidth - Style.space(12)
                - (reconnectButton.visible ? reconnectButton.width + parent.spacing : 0))
              elide: Text.ElideRight
              color: root.connected ? root.dim : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              ToolTip.visible: statusHover.containsMouse && root.serverHost !== ""
              ToolTip.text: root.serverHost

              MouseArea {
                id: statusHover
                anchors.fill: parent
                hoverEnabled: true
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.rosterGroups

            Column {
              id: rosterGroup
              required property var modelData
              required property int index
              readonly property bool last: index === root.rosterGroups.length - 1
              width: parent.width
              spacing: Style.space(4)

              Text {
                visible: rosterGroup.modelData.name !== ""
                text: rosterGroup.modelData.name
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.capitalization: Font.AllUppercase
              }

              Flow {
                width: parent.width
                spacing: Style.spacing.sm

                  Repeater {
                    model: rosterGroup.modelData.bots
                    Button {
                      required property var modelData
                      // root.revision: the status maps are mutated in place, so re-evaluate on every revision bump.
                      text: (root.revision, (modelData.pinned ? "󰐃 " : "") + modelData.name) + (root.waitingOnUser && root.waitingProfile === modelData.name ? " ?"
                        : root.busyProfiles[modelData.name] ? " …" : root.cronRunning[modelData.name] ? " ⏱"
                        : root.unreadProfiles[modelData.name] ? " •" : "")
                      selected: modelData.name === root.selected
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      onClicked: root.selected = modelData.name
                    }
                  }

                  // The roster's own buttons close the last row.
                  Button {
                    visible: rosterGroup.last
                    text: root.creating ? "× cancel" : "+ new bot"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: {
                      if (!root.creating) root.closeDrawers("create")
                      root.creating = !root.creating
                      if (root.creating) Qt.callLater(function() { nameField.forceActiveFocus() })
                    }
                  }

                  Button {
                    visible: rosterGroup.last && root.hiddenCount > 0
                    text: root.showHidden ? "Hide hidden" : "Show hidden (" + root.hiddenCount + ")"
                    bordered: true
                    selected: root.showHidden
                    foreground: root.dim
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: root.showHidden = !root.showHidden
                  }
              }
            }
          }
        }

        // Model caption on its own line; the action buttons wrap instead of overlapping it.
        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            width: parent.width
            elide: Text.ElideRight
            text: {
              root.revision
              var u = root.usageByProfile[root.selected]
              return (root.selectedProfile ? "model · " + root.selectedProfile.model : "")
                + (u ? "  ·  context " + u.contextPercent + "%  ·  " + (u.total >= 1000 ? (u.total / 1000).toFixed(1) + "k" : u.total) + " tokens" : "")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Flow {
            id: botActions
            width: parent.width
            spacing: Style.spacing.sm

            Button {
              text: "History"
              bordered: true
              selected: root.showingSessions
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.toggleSessions()
            }

            Button {
              text: root.searching && root.searchText.trim() !== "" ? "Search · " + root.shownMessages.length : "Search"
              bordered: true
              selected: root.searching
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.toggleSearch()
            }

            Button {
              text: "Routines"
              bordered: true
              selected: root.showingRoutines
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.toggleRoutines()
            }

            Button {
              text: root.roomActions.length > 0 ? "Groups ?" : Object.keys(root.groupUnread).length > 0 ? "Groups •"
                : root.showingGroups && root.roomWorking ? "Groups …" : "Groups"
              bordered: true
              selected: root.showingGroups
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.toggleGroups()
            }

            Button {
              text: "Edit"
              bordered: true
              selected: root.editing
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.toggleEdit()
            }

            Button {
              text: "Screen"
              bordered: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.openScreen()
            }
          }

          // Search filters the chat below; its field gets a row of its own so the buttons never reflow.
          TextField {
            id: searchField
            visible: root.searching
            width: parent.width
            placeholderText: "search this chat (Esc closes)"
            foreground: root.foreground
            text: root.searchText
            onTextChanged: root.searchText = text
            Keys.onEscapePressed: { text = ""; root.searching = false; input.forceActiveFocus() }
          }
        }

        Item {
          visible: root.screenState !== null
          width: parent.width
          implicitHeight: screenActions.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "screen · " + root.screenCaption + (root.demoProfile === root.selected ? " · ● recording demo" : "")
            color: root.screenMine ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            id: screenActions
            anchors.right: parent.right
            spacing: Style.spacing.sm

            Button {
              visible: root.screenState !== null && root.screenState.running && root.demoProfile !== root.selected
              text: "● Record demo"
              bordered: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.startDemo()
            }

            Button {
              visible: root.demoProfile === root.selected
              text: "■ Stop & teach"
              bordered: true
              foreground: root.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.stopDemo()
            }

            Button {
              visible: !root.screenMine
              text: "Take over"
              bordered: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.screenLease("take")
            }

            Button {
              visible: root.screenMine
              text: "Hand back"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.screenLease("handback")
            }
          }
        }

        Item {
          visible: root.skillDraft !== null && root.skillDraft.profile === root.selected
          width: parent.width
          implicitHeight: draftActions.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.right: draftActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: !root.skillDraft ? "" : root.skillDraft.error ? "⚠ /" + root.skillDraft.name + ": " + root.skillDraft.error
              : "🎓 skill draft from your demo: /" + root.skillDraft.name
            color: root.skillDraft && root.skillDraft.error ? root.urgent : Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            id: draftActions
            anchors.right: parent.right
            spacing: Style.spacing.sm

            Button {
              text: root.skillDraft && root.skillDraft.saving ? "Saving…" : "Save skill"
              enabled: !root.skillDraft || !root.skillDraft.saving
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.saveSkillDraft()
            }

            Button {
              text: "Dismiss"
              bordered: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.skillDraft = null
            }
          }
        }

        // The drawers (History, Groups, Routines, Edit, Model, New bot) scroll inside a capped area,
        // so a tall drawer never covers the chat or the composer.
        Flickable {
          id: drawerFlick
          // Bound to the drawer flags, not to drawerColumn's height: a hidden Column is never laid out,
          // so its implicitHeight would stay 0 and the drawer would never appear.
          visible: root.showingSessions || root.showingGroups || root.showingRoutines || root.editing
            || root.pickingModel || root.creating
          width: parent.width
          height: Math.min(drawerColumn.implicitHeight, Math.max(Style.space(110),
            keyCatcher.height - footer.height - y - (root.drawerTakesOver ? Style.space(8) : Style.space(130))))
          contentWidth: width
          contentHeight: drawerColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: drawerColumn
            width: drawerFlick.width
            spacing: header.spacing

            Column {
              visible: root.showingSessions
              width: parent.width
              spacing: Style.space(2)

              PanelSectionHeader {
                text: "HISTORY · @" + root.selected
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                visible: root.sessionList.length === 0
                text: "Loading conversations…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.sessionList.slice(0, 10)
                Item {
                  id: sessionRow
                  required property var modelData
                  readonly property bool renaming: root.renamingSession === modelData.id
                  width: parent.width
                  implicitHeight: sessionTop.height + sessionActions.height + Style.space(10)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: modelData.current ? root.alpha(root.foreground, 0.14) : "transparent"
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: !sessionRow.renaming
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openSession(modelData.id)
                  }

                  Item {
                    id: sessionTop
                    x: Style.space(8)
                    y: Style.space(4)
                    width: parent.width - Style.space(16)
                    height: sessionRow.renaming ? renameField.implicitHeight : sessionMeta.implicitHeight

                    Text {
                      id: sessionMeta
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: Qt.formatDateTime(new Date(modelData.startedAt * 1000), "MM-dd HH:mm")
                        + " · " + modelData.messages + " msgs"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      visible: !sessionRow.renaming
                      anchors.left: parent.left
                      anchors.right: sessionMeta.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      text: (modelData.source === "cron" ? "⏱ " : "") + modelData.title
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    TextField {
                      id: renameField
                      visible: sessionRow.renaming
                      anchors.left: parent.left
                      anchors.right: sessionMeta.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      placeholderText: "title"
                      foreground: root.foreground
                      onVisibleChanged: if (visible) { text = modelData.title; forceActiveFocus() }
                      onAccepted: root.sessionRename(modelData.id, text)
                      Keys.onEscapePressed: root.renamingSession = ""
                    }
                  }

                  Flow {
                    id: sessionActions
                    anchors.top: sessionTop.bottom
                    anchors.topMargin: Style.space(2)
                    x: Style.space(8)
                    width: parent.width - Style.space(16)
                    layoutDirection: Qt.RightToLeft
                    spacing: Style.spacing.sm

                    Button {
                      text: root.armedSessionDelete === modelData.id ? "Click again to delete" : "Delete"
                      foreground: root.armedSessionDelete === modelData.id ? root.urgent : root.dim
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      onClicked: root.requestSessionDelete(modelData.id)
                    }
                    Button {
                      text: "Archive"
                      foreground: root.dim
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      onClicked: root.sessionArchive(modelData.id)
                    }
                    Button {
                      text: sessionRow.renaming ? "Save" : "Rename"
                      foreground: root.dim
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      onClicked: sessionRow.renaming ? root.sessionRename(modelData.id, renameField.text)
                        : root.renamingSession = modelData.id
                    }
                  }
                }
              }
            }

            // Group chats: the room list and a New group form, or the open room with its own composer.
            Column {
              visible: root.showingGroups
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                text: "GROUP CHATS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                visible: root.roomError !== ""
                width: parent.width
                wrapMode: Text.Wrap
                text: "⚠ " + root.roomError
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: root.openRoom === "" && root.groupRooms.length === 0
                text: "No group chats yet."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.openRoom === "" ? root.groupRooms : []
                Item {
                  required property var modelData
                  width: parent.width
                  implicitHeight: roomLine.implicitHeight + Style.space(8)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: roomMouse.containsMouse ? root.alpha(root.foreground, 0.1) : "transparent"
                  }

                  MouseArea {
                    id: roomMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openGroup(modelData.id)
                  }

                  Text {
                    id: roomLine
                    x: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(16)
                    elide: Text.ElideRight
                    text: (root.groupUnread[modelData.id] ? "• " : "") + "󰡉 " + modelData.name + "  ·  "
                      + modelData.members.map(function(m) { return "@" + m }).join(" ")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Text {
                visible: root.openRoom === ""
                text: "New group: pick 2 to 6 bots"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Flow {
                visible: root.openRoom === ""
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.rosterProfiles
                  Button {
                    required property var modelData
                    text: "@" + modelData.name
                    bordered: true
                    selected: root.newGroupMembers[modelData.name] === true
                    foreground: root.dim
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.toggleGroupMember(modelData.name)
                  }
                }
              }

              Item {
                visible: root.openRoom === ""
                width: parent.width
                implicitHeight: Math.max(groupNameField.implicitHeight, createGroupButton.implicitHeight)

                TextField {
                  id: groupNameField
                  anchors.left: parent.left
                  anchors.right: createGroupButton.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "group name"
                  foreground: root.foreground
                  onAccepted: if (root.createGroup(text)) text = ""
                }

                Button {
                  id: createGroupButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  height: groupNameField.height
                  text: "Create group"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: if (root.createGroup(groupNameField.text)) groupNameField.text = ""
                }
              }

              Item {
                visible: root.openRoom !== ""
                width: parent.width
                implicitHeight: roomHeaderButtons.implicitHeight

                Text {
                  anchors.left: parent.left
                  anchors.right: roomHeaderButtons.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: "󰡉 " + (root.openRoomInfo ? root.openRoomInfo.name + "  ·  "
                    + root.openRoomInfo.members.map(function(m) { return "@" + m }).join(" ") : root.openRoom)
                  color: root.foreground
                  font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                }

                Row {
                  id: roomHeaderButtons
                  anchors.right: parent.right
                  spacing: Style.spacing.sm

                  Button {
                    visible: root.roomWorking
                    text: "Stop"
                    bordered: true
                    foreground: root.urgent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.sendCommand({ cmd: "group.stop", room: root.openRoom })
                  }

                  Button {
                    text: "Rename"
                    bordered: true
                    selected: root.renamingRoom
                    foreground: root.dim
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.renamingRoom = !root.renamingRoom
                  }

                  Button {
                    text: root.armedDisband === root.openRoom ? "Click again to delete group" : "Delete group"
                    bordered: true
                    foreground: root.armedDisband === root.openRoom ? root.urgent : root.dim
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.requestDisband()
                  }

                  Button {
                    text: "‹ Groups"
                    bordered: true
                    foreground: root.dim
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.closeRoom()
                  }
                }
              }

              TextField {
                id: roomRenameField
                visible: root.openRoom !== "" && root.renamingRoom
                width: parent.width
                placeholderText: "new group name (Enter to save, Esc to cancel)"
                foreground: root.foreground
                onVisibleChanged: if (visible) { text = root.openRoomInfo ? root.openRoomInfo.name : ""; forceActiveFocus() }
                onAccepted: root.renameRoom(text)
                Keys.onEscapePressed: root.renamingRoom = false
              }

              Rectangle {
                visible: root.openRoom !== ""
                width: parent.width
                // Fills the space the hidden chat leaves; the header row, cards and input take the rest.
                height: Math.max(Style.space(150), keyCatcher.height - footer.height - drawerFlick.y - Style.space(150))
                radius: Style.cornerRadius
                color: root.alpha(root.foreground, 0.04)

                ListView {
                  id: roomView
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  clip: true
                  spacing: Style.space(6)
                  model: root.roomRows
                  onCountChanged: Qt.callLater(function() { roomView.positionViewAtEnd() })

                  // Click a message to reply in its thread; links inside the text still open.
                  delegate: Item {
                    required property var modelData
                    width: roomView.width
                    implicitHeight: rowColumn.implicitHeight

                    Rectangle {
                      anchors.fill: parent
                      anchors.margins: -Style.space(2)
                      radius: Style.cornerRadius
                      color: root.roomReply && modelData.thread && root.roomReply.thread === modelData.thread
                        ? root.alpha(Color.accent, 0.12) : "transparent"
                    }

                    MouseArea {
                      anchors.fill: parent
                      enabled: modelData.role !== "status" && !!modelData.thread
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.replyInRoom(modelData)
                    }

                    Column {
                    id: rowColumn
                    width: parent.width
                    spacing: Style.space(1)

                    Text {
                      visible: modelData.role !== "status"
                      text: modelData.role === "you" ? "you" : "@" + modelData.who
                      color: modelData.role === "you" ? root.dim : root.linkColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    Text {
                      visible: modelData.role !== "bot"
                      width: parent.width
                      wrapMode: Text.Wrap
                      text: modelData.role === "status" ? (modelData.who ? "@" + modelData.who + " " : "") + modelData.text
                        : modelData.text
                      textFormat: Text.PlainText
                      color: modelData.role === "status" ? root.dim : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: modelData.role === "status" ? Style.font.caption : Style.font.bodySmall
                    }

                    MarkdownBody {
                      visible: modelData.role === "bot"
                      width: parent.width
                      markdown: modelData.role === "bot" ? root.displayText(modelData.text) : ""
                      color: root.foreground
                      linkColor: root.linkColor
                      codeBackground: root.alpha(root.foreground, 0.10)
                      fontFamily: root.fontFamily
                      pixelSize: Style.font.bodySmall
                      radius: Style.cornerRadius
                    }
                    }
                  }
                }

                Text {
                  anchors.centerIn: parent
                  visible: root.roomRows.length === 0
                  text: "No messages yet. @mention a bot, or write to everyone."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                visible: root.openRoom !== "" && root.roomWorking
                text: "… bots are replying"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.openRoom !== "" ? root.roomActions : []
                Rectangle {
                  id: actionCard
                  required property var modelData
                  readonly property var action: modelData
                  width: parent.width
                  implicitHeight: actionColumn.implicitHeight + Style.space(12)
                  radius: Style.cornerRadius
                  color: root.alpha(root.urgent, 0.10)
                  border.width: 1
                  border.color: root.alpha(root.urgent, 0.4)

                  Column {
                    id: actionColumn
                    x: Style.space(6)
                    y: Style.space(6)
                    width: parent.width - Style.space(12)
                    spacing: Style.space(4)

                    Text {
                      width: parent.width
                      wrapMode: Text.Wrap
                      text: actionCard.action.kind === "approval"
                        ? "@" + actionCard.action.member + " needs approval: " + (actionCard.action.description || actionCard.action.command)
                        : "A turn ended without a clear result and waits for a retry."
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      visible: actionCard.action.kind === "approval" && actionCard.action.description !== "" && actionCard.action.command !== ""
                      width: parent.width
                      wrapMode: Text.Wrap
                      text: actionCard.action.command || ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Row {
                      spacing: Style.spacing.sm

                      Repeater {
                        model: actionCard.action.kind === "approval" ? actionCard.action.choices : ["retry"]
                        Button {
                          required property var modelData
                          text: modelData === "once" ? "Approve once" : modelData === "deny" ? "Deny" : modelData === "retry" ? "Retry" : modelData
                          bordered: true
                          foreground: modelData === "deny" ? root.urgent : root.foreground
                          fontFamily: root.fontFamily
                          fontSize: Style.font.caption
                          onClicked: modelData === "retry" ? root.retryRoomTask(actionCard.action.taskId)
                            : root.answerRoomApproval(actionCard.action, modelData)
                        }
                      }
                    }
                  }
                }
              }

              Item {
                visible: root.openRoom !== "" && root.roomReply !== null
                width: parent.width
                implicitHeight: replyLine.implicitHeight

                Text {
                  id: replyLine
                  anchors.left: parent.left
                  anchors.right: replyCancel.left
                  anchors.rightMargin: Style.space(8)
                  elide: Text.ElideRight
                  text: root.roomReply ? "↩ in thread" + (root.roomReply.who ? " with @" + root.roomReply.who : "") + ": "
                    + root.roomReply.text.replace(/\s+/g, " ") : ""
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: replyCancel
                  anchors.right: parent.right
                  anchors.verticalCenter: replyLine.verticalCenter
                  text: "×"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.roomReply = null
                  }
                }
              }

              TextField {
                id: roomInput
                visible: root.openRoom !== ""
                width: parent.width
                placeholderText: root.roomReply ? "Reply in this thread" : "Message the group  (@bot to address one)"
                foreground: root.foreground
                onAccepted: if (root.sendToRoom(text)) text = ""
              }
            }

            Column {
              visible: root.showingRoutines
              width: parent.width
              spacing: Style.space(2)

              PanelSectionHeader {
                text: "ROUTINES · @" + root.selected
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                visible: root.routines.length === 0
                text: root.routinesLoaded ? "No routines for @" + root.selected : "Loading routines…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.routines
                Column {
                  id: routineRow
                  required property var modelData
                  readonly property var runs: { root.revision; return root.routineRunsById[modelData.id] || null }
                  width: parent.width
                  spacing: Style.space(2)

                  Item {
                    width: parent.width
                    implicitHeight: routineButtons.implicitHeight + Style.space(4)

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.right: routineButtons.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      text: routineRow.modelData.name + " · " + routineRow.modelData.schedule_display
                        + " · next " + (routineRow.modelData.paused ? "paused" : root.formatWhen(routineRow.modelData.next_run_at))
                        + " · last " + (routineRow.modelData.last_status || "—")
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      color: routineRow.modelData.last_status && routineRow.modelData.last_status !== "ok" ? root.urgent
                        : routineRow.modelData.paused ? root.dim : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Row {
                      id: routineButtons
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(4)

                      Button {
                        text: "Runs"
                        bordered: true
                        selected: root.routineRunsShown === routineRow.modelData.id
                        foreground: root.dim
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        onClicked: root.toggleRoutineRuns(routineRow.modelData.id)
                      }
                      Button {
                        text: "Run"
                        bordered: true
                        foreground: root.dim
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        onClicked: root.routineCommand("run", routineRow.modelData.id)
                      }
                      Button {
                        text: routineRow.modelData.paused ? "Resume" : "Pause"
                        bordered: true
                        foreground: root.dim
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        onClicked: root.routineCommand(routineRow.modelData.paused ? "resume" : "pause", routineRow.modelData.id)
                      }
                      Button {
                        text: root.armedRoutine === routineRow.modelData.id ? "Confirm" : "Delete"
                        bordered: true
                        foreground: root.armedRoutine === routineRow.modelData.id ? root.urgent : root.dim
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        onClicked: root.requestRoutineDelete(routineRow.modelData.id)
                      }
                    }
                  }

                  Text {
                    visible: root.routineRunsShown === routineRow.modelData.id && (routineRow.runs === null || routineRow.runs.length === 0)
                    leftPadding: Style.space(20)
                    text: routineRow.runs === null ? "Loading runs…" : "No runs yet"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Repeater {
                    model: root.routineRunsShown === routineRow.modelData.id && routineRow.runs ? routineRow.runs : []
                    Text {
                      required property var modelData
                      width: routineRow.width
                      leftPadding: Style.space(20)
                      rightPadding: Style.space(8)
                      text: root.formatWhen(modelData.started_at) + (modelData.end_reason ? " · " + modelData.end_reason : "")
                        + (modelData.title ? " · " + modelData.title : "")
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.sm

                TextField {
                  id: routineNameField
                  width: (parent.width - routineCreateButton.width - parent.spacing * 3) * 0.25
                  placeholderText: "name"
                  foreground: root.foreground
                  onAccepted: routineScheduleField.forceActiveFocus()
                }
                TextField {
                  id: routineScheduleField
                  width: (parent.width - routineCreateButton.width - parent.spacing * 3) * 0.25
                  placeholderText: "every 1h"
                  foreground: root.foreground
                  onAccepted: routinePromptField.forceActiveFocus()
                }
                TextField {
                  id: routinePromptField
                  width: (parent.width - routineCreateButton.width - parent.spacing * 3) * 0.5
                  placeholderText: "prompt"
                  foreground: root.foreground
                  onAccepted: root.createRoutine(routineNameField.text, routineScheduleField.text, text)
                }
                Button {
                  id: routineCreateButton
                  height: routineNameField.height
                  text: "Create"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.createRoutine(routineNameField.text, routineScheduleField.text, routinePromptField.text)
                }
              }
            }

            Column {
              visible: root.editing
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                text: "EDIT · @" + root.selected + (root.selectedInfo ? "" : "  (loading…)")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                text: "Description"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: editDescField
                width: parent.width
                placeholderText: "role / description"
                foreground: root.foreground
              }

              Text {
                text: "SOUL.md · persona and standing instructions"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              ScrollView {
                width: parent.width
                height: Style.space(120)
                clip: true

                TextArea {
                  id: soulArea
                  wrapMode: TextEdit.Wrap
                  placeholderText: "persona / standing instructions"
                  color: root.foreground
                  placeholderTextColor: root.dim
                  selectionColor: root.alpha(Color.accent, 0.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  background: Rectangle {
                    radius: Style.cornerRadius
                    color: root.alpha(root.foreground, 0.06)
                    border.width: 1
                    border.color: root.alpha(root.foreground, soulArea.activeFocus ? 0.5 : 0.2)
                  }
                }
              }

              Row {
                spacing: Style.spacing.sm

                Button {
                  text: "Save"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.saveProfile(editDescField.text, soulArea.text)
                }

                Button {
                  text: root.selectedInfo && root.selectedInfo.pinned ? "󰐃 Pinned" : "Pin"
                  bordered: true
                  selected: root.selectedInfo !== null && root.selectedInfo.pinned === true
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.setProfileFlag("pinned", !(root.selectedInfo && root.selectedInfo.pinned))
                }

                Button {
                  text: root.selectedInfo && root.selectedInfo.hidden ? "Hidden" : "Hide"
                  bordered: true
                  selected: root.selectedInfo !== null && root.selectedInfo.hidden === true
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.setProfileFlag("hidden", !(root.selectedInfo && root.selectedInfo.hidden))
                }
              }

              PanelSectionHeader {
                topPadding: Style.space(8)
                text: "SECTION"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Flow {
                visible: root.sectionOrder.length > 0
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.sectionOrder
                  Button {
                    required property string modelData
                    text: modelData
                    bordered: true
                    selected: root.selectedSection === modelData
                    foreground: root.dim
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    // Clicking the bot's own section takes it out again.
                    onClicked: root.setSection(selected ? "" : modelData)
                  }
                }
              }

              Item {
                width: parent.width
                implicitHeight: sectionField.implicitHeight

                TextField {
                  id: sectionField
                  anchors.left: parent.left
                  anchors.right: sectionButton.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "new section for @" + root.selected
                  foreground: root.foreground
                  onAccepted: {
                    if (text.trim() === "") return
                    root.setSection(text)
                    text = ""
                  }
                }

                Button {
                  id: sectionButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  height: sectionField.height
                  text: "Move"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: {
                    if (sectionField.text.trim() === "") return
                    root.setSection(sectionField.text)
                    sectionField.text = ""
                  }
                }
              }

              PanelSectionHeader {
                topPadding: Style.space(8)
                text: "SAVE YOUR LAST MESSAGE AS A SKILL"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Item {
                width: parent.width
                implicitHeight: skillNameField.implicitHeight

                TextField {
                  id: skillNameField
                  anchors.left: parent.left
                  anchors.right: saveSkillButton.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "skill name, e.g. weekly-report"
                  foreground: root.foreground
                  onAccepted: { if (root.saveLastPromptAsSkill(text)) text = "" }
                }

                Button {
                  id: saveSkillButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  height: skillNameField.height
                  text: "Save as skill"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: { if (root.saveLastPromptAsSkill(skillNameField.text)) skillNameField.text = "" }
                }
              }

              PanelSectionHeader {
                topPadding: Style.space(8)
                text: "COPY AND SHARE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Item {
                width: parent.width
                implicitHeight: duplicateField.implicitHeight

                TextField {
                  id: duplicateField
                  anchors.left: parent.left
                  anchors.right: duplicateButton.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "name for a copy of @" + root.selected
                  foreground: root.foreground
                  onAccepted: root.duplicateProfile(text)
                }

                Button {
                  id: duplicateButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  height: duplicateField.height
                  text: "Duplicate"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.duplicateProfile(duplicateField.text)
                }
              }

              Item {
                width: parent.width
                implicitHeight: exportButton.implicitHeight

                Text {
                  anchors.left: parent.left
                  anchors.right: exportButton.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Template file: ~/Downloads/hermes-bot-" + root.selected + ".json"
                  elide: Text.ElideMiddle
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Button {
                  id: exportButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Export"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.sendCommand({ cmd: "template.export", profile: root.selected })
                }
              }

              Item {
                width: parent.width
                implicitHeight: importPathField.implicitHeight

                TextField {
                  id: importPathField
                  anchors.left: parent.left
                  anchors.right: importNameField.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "template .json path"
                  foreground: root.foreground
                  onAccepted: importNameField.forceActiveFocus()
                }

                TextField {
                  id: importNameField
                  anchors.right: importButton.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(110)
                  placeholderText: "new bot name"
                  foreground: root.foreground
                  onAccepted: root.sendCommand({ cmd: "template.import", path: importPathField.text, name: text })
                }

                Button {
                  id: importButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  height: importPathField.height
                  text: "Import"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.sendCommand({ cmd: "template.import", path: importPathField.text, name: importNameField.text })
                }
              }

              PanelSectionHeader {
                visible: root.selected !== "default"
                topPadding: Style.space(8)
                text: "DELETE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Button {
                visible: root.selected !== "default"
                text: root.armedDelete === root.selected ? "Click again to delete @" + root.selected + " for good" : "Delete @" + root.selected
                bordered: true
                foreground: root.urgent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.requestDelete(root.selected)
              }
            }

            Column {
              visible: root.pickingModel
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                text: "MODEL · @" + root.selected
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Flow {
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.modelPresets
                  Button {
                    required property var modelData
                    text: modelData
                    selected: root.selectedProfile && root.selectedProfile.model === modelData
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.setModel(modelData)
                  }
                }

                TextField {
                  id: modelField
                  width: Style.space(200)
                  placeholderText: "other model id"
                  foreground: root.foreground
                  onAccepted: { root.setModel(text); text = "" }
                }
              }
            }

            Column {
              visible: root.creating
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                text: "NEW BOT"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                width: parent.width
                spacing: Style.spacing.sm

                TextField {
                  id: nameField
                  width: (parent.width - createBotButton.width - parent.spacing * 2) * 0.35
                  placeholderText: "name"
                  foreground: root.foreground
                  onAccepted: descField.forceActiveFocus()
                }

                TextField {
                  id: descField
                  width: (parent.width - createBotButton.width - parent.spacing * 2) * 0.65
                  placeholderText: "role / description"
                  foreground: root.foreground
                  onAccepted: root.createBot()
                }

                Button {
                  id: createBotButton
                  height: nameField.height
                  text: "Create"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.createBot()
                }
              }
            }
          }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          text: root.lastError
          color: root.urgent
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.noticeList
          Rectangle {
            required property var modelData
            width: parent.width
            height: noticeText.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            // root.alpha() needs a color value, not a "#hex" string, so the warn/success tints are built here.
            readonly property color tone: modelData.level === "error" ? root.urgent
              : modelData.level === "warn" ? Qt.rgba(0.88, 0.63, 0.31, 1)
              : modelData.level === "success" ? Qt.rgba(0.5, 0.75, 0.5, 1) : Color.accent
            color: root.alpha(tone, 0.2)
            border.width: 1
            border.color: root.alpha(tone, 0.6)
            Text {
              id: noticeText
              anchors.left: parent.left
              anchors.right: noticeClose.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              text: modelData.text
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              id: noticeClose
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "×"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: root.dismissNotice(modelData.key) }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }
      }

      Flickable {
        id: chatFlick
        visible: !root.drawerTakesOver
        anchors.top: header.bottom
        anchors.topMargin: Style.space(8)
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(8)
        width: parent.width
        contentWidth: width
        contentHeight: chatColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        onContentHeightChanged: contentY = Math.max(0, contentHeight - height)
        // The footer (todo list, cards) grows and shrinks the chat; keep the newest row in view.
        onHeightChanged: contentY = Math.max(0, contentHeight - height)

        Column {
          id: chatColumn
          width: chatFlick.width
          spacing: Style.space(8)

          Text {
            visible: root.messages.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "Say something to @" + root.selected
            color: root.dim
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: chatModel

            Rectangle {
              // One transcript row as JSON, kept current by syncChat.
              required property string row
              readonly property var modelData: JSON.parse(row)
              readonly property bool mine: modelData.role === "you"
              readonly property bool isBot: modelData.role === "bot"
              readonly property Item bubbleBody: isBot ? bubbleMarkdown : bubbleText
              readonly property bool isTool: modelData.role === "tool"
              readonly property var images: modelData.images || []
              readonly property var files: modelData.files || []
              readonly property bool foldable: !!modelData.full
              readonly property bool scaffold: !!modelData.scaffold
              property bool expanded: false
              width: isTool ? parent.width
                : images.length > 0 || files.length > 0 || scaffold ? parent.width * 0.88
                : Math.min(parent.width * 0.88, isBot ? bubbleMarkdown.naturalWidth + Style.space(34)
                                                       : bubbleText.implicitWidth + Style.space(20))
              x: mine ? parent.width - width : 0
              implicitHeight: (bubbleBody.visible ? bubbleBody.implicitHeight : 0) + imageColumn.implicitHeight
                + Style.space(12)
              radius: Style.cornerRadius
              color: isTool ? "transparent" : root.alpha(root.foreground, mine ? 0.14 : 0.06)

              MouseArea {
                anchors.fill: parent
                enabled: parent.foldable
                cursorShape: Qt.PointingHandCursor
                onClicked: parent.expanded = !parent.expanded
              }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: root.quoteRow(parent.modelData)
              }

              Text {
                visible: modelData.role === "bot" && root.displayText(modelData.text) !== ""
                z: 2
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                text: root.speaking ? "󰓛" : "󰕾"
                opacity: 0.55
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -4
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.speakText(modelData.text)
                }
              }

              Text {
                id: bubbleText
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(6)
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                visible: text !== ""
                text: isBot ? ""
                  : foldable && expanded ? String(modelData.full).trim()
                  : scaffold ? "⏱ scheduled job prompt — click to expand"
                  : root.attachmentRefs(String(modelData.text || "").trim())
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: isTool ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: isTool ? Style.font.caption : Style.font.bodySmall
              }

              MarkdownBody {
                id: bubbleMarkdown
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(6)
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(24)
                visible: markdown !== ""
                markdown: isBot ? root.displayText(modelData.text) : ""
                color: root.foreground
                linkColor: root.linkColor
                codeBackground: root.alpha(root.foreground, 0.10)
                fontFamily: root.fontFamily
                pixelSize: Style.font.bodySmall
                radius: Style.cornerRadius
              }

              Column {
                id: imageColumn
                anchors.top: bubbleBody.visible ? bubbleBody.bottom : parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(6)
                spacing: Style.space(6)

                Text {
                  visible: scaffold && !expanded
                  width: parent.width
                  text: modelData.summary || ""
                  elide: Text.ElideRight
                  wrapMode: Text.NoWrap
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: images

                  Image {
                    required property var modelData
                    width: parent.width
                    height: Style.space(180)
                    source: "file://" + modelData
                    fillMode: Image.PreserveAspectFit
                    horizontalAlignment: mine ? Image.AlignRight : Image.AlignLeft
                    asynchronous: true
                    smooth: true

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: Qt.openUrlExternally("file://" + modelData)
                    }
                  }
                }

                Repeater {
                  model: files

                  Rectangle {
                    required property var modelData
                    width: Math.min(parent.width, fileLabel.implicitWidth + Style.space(16))
                    height: fileLabel.implicitHeight + Style.space(8)
                    x: mine ? parent.width - width : 0
                    radius: Style.cornerRadius
                    color: root.alpha(root.foreground, 0.10)

                    Text {
                      id: fileLabel
                      x: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - Style.space(16)
                      text: "󰈔 " + modelData.name
                      elide: Text.ElideMiddle
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      enabled: !!modelData.local
                      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: root.openFile(modelData.local)
                    }
                  }
                }
              }
            }
          }
        }
      }

      Column {
        id: footer
        anchors.bottom: parent.bottom
        width: parent.width
        spacing: Style.space(6)

        BorderSurface {
          visible: root.clarifyQuestion !== null
          width: parent.width
          implicitHeight: clarifyColumn.implicitHeight + Style.space(16)
          color: root.alpha(Color.accent, 0.10)
          borderSpec: Border.flat(root.alpha(Color.accent, 0.45), 1)
          radius: Style.cornerRadius

          Column {
            id: clarifyColumn
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.clarifyQuestion
                ? "@" + root.waitingProfile + " asks "
                  + (root.clarify.questions.length > 1 ? "(" + (root.clarifyIndex + 1) + "/" + root.clarify.questions.length + ") " : "")
                  + "— "
                  + root.clarifyQuestion.question
                : ""
              color: root.foreground
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Flow {
              width: parent.width
              spacing: Style.spacing.sm
              Repeater {
                model: root.clarifyQuestion ? root.clarifyQuestion.choices : []
                Button {
                  required property var modelData
                  text: modelData
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.answerClarify(String(modelData).replace(/ \(Recommended\)$/, ""))
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm
              TextField {
                id: clarifyField
                width: parent.width - skipButton.width - parent.spacing
                placeholderText: "Type an answer"
                foreground: root.foreground
                onAccepted: root.answerClarify(text)
              }
              Button {
                id: skipButton
                text: "Skip"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.answerClarify("")
              }
            }
          }
        }

        BorderSurface {
          visible: root.approval !== null
          width: parent.width
          implicitHeight: approvalColumn.implicitHeight + Style.space(16)
          color: root.alpha(root.urgent, 0.10)
          borderSpec: Border.flat(root.alpha(root.urgent, 0.4), 1)
          radius: Style.cornerRadius

          Column {
            id: approvalColumn
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.approvalDraft ? "✉ Draft to " + (root.approvalDraft.target || "the default target")
                  + ". Nothing is sent until you press Send."
                : root.approval ? ("Approval needed: " + (root.approval.description || root.approval.command)) : ""
              color: root.foreground
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: root.approvalDraft !== null
            }

            Text {
              visible: root.approvalDraft !== null
              width: parent.width
              text: root.approvalDraft ? root.approvalDraft.body : ""
              textFormat: Text.PlainText
              color: root.foreground
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Drafts only offer a one-off send: "session"/"always" would skip review for later messages.
            Row {
              visible: root.approvalDraft !== null
              spacing: Style.spacing.sm

              Button {
                visible: root.approval !== null && root.approval.choices.indexOf("once") >= 0
                text: "Send"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.answerApproval("once")
              }

              Button {
                text: "Edit…"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.editDraft()
              }

              Button {
                text: "Discard"
                bordered: true
                foreground: root.urgent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.answerApproval("deny")
              }
            }

            Row {
              visible: root.approvalDraft === null
              spacing: Style.spacing.sm
              Repeater {
                model: root.approval && root.approvalDraft === null ? root.approval.choices : []
                Button {
                  required property var modelData
                  text: modelData
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.answerApproval(modelData)
                }
              }
            }
          }
        }

        // One Text per item: ElideRight does not elide the lines of a multi-line NoWrap Text.
        Column {
          visible: root.selectedTodos.length > 0
          width: parent.width

          Repeater {
            model: root.selectedTodos.slice(0, 8)
            Text {
              required property var modelData
              width: parent.width
              text: (modelData.status === "completed" ? "☑ " : modelData.status === "in_progress" ? "◐ "
                : modelData.status === "cancelled" ? "☒ " : "☐ ") + modelData.text
              elide: Text.ElideRight
              wrapMode: Text.NoWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          visible: root.activityLine !== ""
          width: parent.width
          text: root.activityLine
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          SequentialAnimation on opacity {
            running: root.activityLine !== ""
            loops: Animation.Infinite
            NumberAnimation { from: 1; to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.45; to: 1; duration: 900; easing.type: Easing.InOutQuad }
          }
        }

        Row {
          visible: root.quoteText !== ""
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            width: parent.width - quoteClear.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "↩ replying to: " + root.quoteText.split("\n")[0]
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            id: quoteClear
            text: "×"
            bordered: true
            foreground: root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.quoteText = ""
          }
        }

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          visible: root.pendingImages.length > 0 || root.pendingFiles.length > 0

          Repeater {
            model: root.pendingImages
            Image {
              required property var modelData
              width: Style.space(44)
              height: Style.space(44)
              source: "file://" + modelData
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
            }
          }

          Repeater {
            model: root.pendingFiles
            Rectangle {
              required property var modelData
              width: Math.min(Style.space(220), fileLabel.implicitWidth + Style.space(16))
              height: fileLabel.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: root.alpha(root.foreground, 0.10)

              Text {
                id: fileLabel
                x: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(16)
                text: "󰈔 " + modelData.name
                elide: Text.ElideMiddle
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                enabled: !!modelData.local
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.openFile(modelData.local)
              }
            }
          }
        }

        Row {
          visible: root.attachOpen
          width: parent.width
          spacing: Style.spacing.sm

          Button {
            id: pasteButton
            text: root.attaching ? "Uploading…" : "Paste clipboard"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.attachFrom("clipboard")
          }

          TextField {
            id: attachField
            width: parent.width - pasteButton.width - parent.spacing
            placeholderText: "or file path (image, pdf, csv, …), then Enter"
            foreground: root.foreground
            onAccepted: { if (root.attachFrom(text)) text = "" }
          }
        }

        // Skill suggestions for "/prefix": Up/Down move, Tab or click completes, Esc closes.
        Column {
          visible: root.skillMatches.length > 0
          width: parent.width

          Repeater {
            model: root.skillMatches
            Item {
              required property var modelData
              required property int index
              width: parent.width
              implicitHeight: skillLabel.implicitHeight + Style.space(6)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: index === root.skillIndex ? root.alpha(root.foreground, 0.14) : "transparent"
              }

              Text {
                id: skillLabel
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "/" + modelData.name + (modelData.description ? " — " + modelData.description : "")
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.completeSkill(index); input.forceActiveFocus() }
              }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          // Multi-line composer: Enter sends, Shift+Enter inserts a newline. Grows to ~5 lines, then scrolls.
          ScrollView {
            width: parent.width - sendButton.width - modelButton.width - parent.spacing * 2
              - (root.busy ? steerButton.width + queueButton.width + parent.spacing * 2
                : newButton.width + imageButton.width + micButton.width + parent.spacing * 3)
            height: Math.min(Math.max(input.implicitHeight, sendButton.height), Style.space(130))
            clip: true

            TextArea {
              id: input
              wrapMode: TextEdit.Wrap
              placeholderText: root.busy ? "Steer @" + root.selected + " (Enter)"
                : "Message @" + root.selected
              enabled: root.connected
              color: root.foreground
              placeholderTextColor: root.dim
              selectionColor: root.alpha(Color.accent, 0.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              background: Rectangle {
                radius: Style.cornerRadius
                color: root.alpha(root.foreground, 0.06)
                border.width: 1
                border.color: root.alpha(root.foreground, input.activeFocus ? 0.5 : 0.2)
              }
              onTextChanged: {
                root.composerText = text
                root.skillsDismissed = false
                root.skillIndex = 0
                if (text === "/" && root.skillsByProfile[root.selected] === undefined) root.refreshSkills()
              }
              Keys.onPressed: function(event) {
                var n = root.skillMatches.length
                if (n > 0 && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
                  event.accepted = true
                  root.skillIndex = (root.skillIndex + (event.key === Qt.Key_Up ? n - 1 : 1)) % n
                } else if (n > 0 && event.key === Qt.Key_Tab) {
                  event.accepted = true
                  root.completeSkill(root.skillIndex)
                } else if (n > 0 && event.key === Qt.Key_Escape) {
                  event.accepted = true
                  root.skillsDismissed = true
                } else if (event.key === Qt.Key_Escape) {
                  event.accepted = true
                  root.close()
                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                    && !(event.modifiers & Qt.ShiftModifier)
                    && input.preeditText === "") {
                  // While a Hangul syllable is still being composed, Enter belongs to the IME.
                  event.accepted = true
                  root.submit()
                }
              }
            }
          }

          Button {
            id: micButton
            visible: !root.busy
            width: visible ? implicitWidth : 0
            height: sendButton.height
            iconText: root.recording ? "󰓛" : "󰍬"
            tooltipText: root.recording ? "Stop dictation" : "Dictate (speech to text)"
            bordered: true
            selected: root.recording
            foreground: root.recording ? root.urgent : root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.toggleDictation()
          }

          Button {
            id: imageButton
            visible: !root.busy
            height: sendButton.height
            iconText: "󰏢"
            text: root.pendingImages.length + root.pendingFiles.length > 0 ? String(root.pendingImages.length + root.pendingFiles.length) : ""
            tooltipText: "Attach an image or file"
            bordered: true
            selected: root.attachOpen
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.attachOpen = !root.attachOpen
          }

          Button {
            id: modelButton
            height: sendButton.height
            iconText: "󰧑"
            tooltipText: "Model" + (root.selectedProfile ? ": " + root.selectedProfile.model : "")
            bordered: true
            selected: root.pickingModel
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.toggleModelPicker()
          }

          Button {
            id: newButton
            visible: !root.busy
            height: sendButton.height
            iconText: "󰐕"
            tooltipText: "New chat (Ctrl+N)"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.newChat()
          }

          Button {
            id: steerButton
            visible: root.busy
            text: "Steer"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: { if (root.steerText(input.text, "steer")) input.text = "" }
          }

          Button {
            id: queueButton
            visible: root.busy
            text: "Queue"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: { if (root.steerText(input.text, "queue")) input.text = "" }
          }

          Button {
            id: sendButton
            text: root.busy ? "Stop" : "Send"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.busy ? root.sendCommand({ cmd: "interrupt", profile: root.selected }) : root.submit()
          }
        }
      }
    }
  }
}
