# wadjet

A macOS-native screenshot and screen-recording utility where every capture runs through a user-defined workflow, ending wherever the user chooses (disk, clipboard, their own upload server).

## Language

### Capturing

**Capture**:
One Screenshot or Recording made with a Capture or Record Tool and processed by a Workflow, together with its file and any upload result.
The file is temporary and wadjet clears it after a while, unless a Save file Step keeps a permanent copy.
_Avoid_: Shot, grab, snip

**Freeze Frame**:
A still of every screen, cursor included, taken the moment a Shortcut or the menu opens a Tool; every Tool works on the Freeze Frame instead of the live screen.
_Avoid_: Frozen screen, snapshot

**Tool**:
One thing to do on the Freeze Frame, picked from the toolbar: Capture region, window, or screen; Record region, window, or screen; Pick colour; Copy text; or Measure.
Capture and Record Tools produce a Capture for a Workflow. The other Tools put their result on the clipboard and run no Workflow.
_Avoid_: Capture Mode, mode

**Screenshot**:
A Capture that is a still image.
_Avoid_: Snap, still

**Recording**:
A Capture that is a video or GIF rather than a still image.
_Avoid_: Screencast, video capture

### Customisation

**Shortcut**:
A hotkey that opens the Freeze Frame on one Tool with set options, and can name the Workflow that processes the Capture.
_Avoid_: Hotkey binding, keybind

**Workflow**:
A named recipe for either Screenshots or Recordings: an ordered list of After-Capture Steps, an optional Destination, and an ordered list of After-Upload Steps.
Screenshots and Recordings each have a default Workflow, which a Shortcut or the toolbar can override.
_Avoid_: Profile, preset, task

**Step**:
One configured action in a Workflow's pipeline, run after capture or after upload, e.g. save to disk or copy image.
A Workflow can repeat an action as separate Steps, each with its own options.
_Avoid_: Action, task, hook

**Destination**:
Where a Workflow uploads a Capture: a Wadjet Server, Google Drive, Dropbox, OneDrive, S3-compatible storage, WebDAV, SFTP, or a Custom Destination defined in ShareX's `.sxcu` format.
_Avoid_: Uploader, host, service

**Wadjet Server**:
Any server that speaks wadjet's own upload protocol: upload, list, and delete, with an API key or OAuth. i.mia.cx is one.
_Avoid_: Backend, i.mia.cx (when meaning any such server)
