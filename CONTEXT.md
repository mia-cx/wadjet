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

### Markup

**Markup Tool**:
A Tool in the toolbar's Markup group that draws Annotations anywhere on the live screen or the Freeze Frame, with no region selection.
It captures nothing itself; Capture and Record Tools capture whatever Annotations are on screen.
_Avoid_: Drawing tool, annotation tool

**Annotation**:
One object drawn or pasted with Markup, such as a shape, line, text, step counter, pasted image, or pasted Canvas. Annotations stack as layers; each stays on screen until erased or cleared, and stays editable inside a Canvas.
_Avoid_: A markup, drawing, mark

**Canvas**:
wadjet's editable image document, saved as a `.wadjet` file: the whole uncropped screen, the crop and its corner radius, and every Annotation as its own layer.
History keeps a Canvas for each Screenshot; the clipboard and the Workflow get the flattened image.
_Avoid_: Project, document, layered image

**Editor**:
The window that opens a Canvas or any image file to recrop it and edit its Annotations, then save, copy, share, or run a Screenshot Workflow on the result.
_Avoid_: Annotate window, viewer

### Customisation

**Shortcut**:
A hotkey that opens the Freeze Frame on one Tool with set options, and can name the Workflow that processes the Capture.
_Avoid_: Hotkey binding, keybind

**Workflow**:
A named recipe for either Screenshots or Recordings: an ordered list of After-Capture Steps, an optional Destination, and an ordered list of After-Upload Steps.
Screenshots and Recordings each have a default Workflow, which a Shortcut or a Tool's menu in the toolbar can override.
_Avoid_: Profile, preset, task

**Step**:
One configured action in a Workflow's pipeline, run after capture or after upload, e.g. save to disk or copy image.
A Workflow can repeat an action as separate Steps, each with its own options.
_Avoid_: Action, task, hook

**Destination**:
Where a Workflow uploads a Capture: a Wadjet Server, Google Drive, Dropbox, OneDrive, S3-compatible storage, WebDAV, SFTP, or a Custom Destination defined in ShareX's `.sxcu` format.
_Avoid_: Uploader, host, service

**Wadjet Server**:
Any server that speaks wadjet's own upload protocol: upload, list, and delete, with an API key or OAuth. wadjet ships one, and w.mia.cx will run it.
_Avoid_: Backend, i.mia.cx
