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
import {hooks as colocatedHooks} from "phoenix-colocated/todos_mcp"
import topbar from "../vendor/topbar"

// Custom hooks
const Hooks = {
  Modal: {
    mounted() {
      // Open modal via custom event
      this.el.addEventListener("modal:open", () => {
        this.el.showModal()
      })
      // Close modal via custom event
      this.el.addEventListener("modal:close", () => {
        this.el.close()
      })
    }
  },
  ScrollToBottom: {
    mounted() {
      this.scrollToBottom()
    },
    updated() {
      this.scrollToBottom()
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    }
  },
  MaintainFocus: {
    mounted() {
      this.maybeFocus()
    },
    updated() {
      // Refocus after LiveView updates (e.g., after form submit clears input)
      this.maybeFocus()
    },
    maybeFocus() {
      // Don't focus if disabled
      if (!this.el.disabled) {
        this.el.focus()
      }
    }
  },
  AudioRecorder: {
    mounted() {
      this.mediaRecorder = null
      this.audioChunks = []
      this.recording = false

      this.el.addEventListener("click", () => this.toggleRecording())
    },

    async toggleRecording() {
      if (this.recording) {
        this.stopRecording()
      } else {
        await this.startRecording()
      }
    },

    async startRecording() {
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
        
        // Use webm format (widely supported, good compression)
        const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') 
          ? 'audio/webm;codecs=opus' 
          : 'audio/webm'
        
        this.mediaRecorder = new MediaRecorder(stream, { mimeType })
        this.audioChunks = []

        this.mediaRecorder.ondataavailable = (event) => {
          if (event.data.size > 0) {
            this.audioChunks.push(event.data)
          }
        }

        this.mediaRecorder.onstop = () => {
          const audioBlob = new Blob(this.audioChunks, { type: mimeType })
          this.sendAudio(audioBlob)
          
          // Stop all tracks to release microphone
          stream.getTracks().forEach(track => track.stop())
        }

        this.mediaRecorder.start()
        this.recording = true
        this.el.classList.add("recording")
        this.pushEvent("recording_started", {})
      } catch (err) {
        console.error("Failed to start recording:", err)
        this.pushEvent("recording_error", { error: err.message })
      }
    },

    stopRecording() {
      if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
        this.mediaRecorder.stop()
        this.recording = false
        this.el.classList.remove("recording")
      }
    },

    async sendAudio(blob) {
      // Convert blob to base64
      const reader = new FileReader()
      reader.onloadend = () => {
        // reader.result is "data:audio/webm;base64,XXXXX"
        // We want just the base64 part
        const base64 = reader.result.split(',')[1]
        this.pushEvent("audio_recorded", { 
          audio: base64, 
          format: "webm",
          size: blob.size 
        })
      }
      reader.readAsDataURL(blob)
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
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

