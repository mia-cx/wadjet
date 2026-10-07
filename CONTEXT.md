# wadjet

A macOS-native screenshot and screen-recording utility where every capture runs through a user-defined workflow, ending wherever the user chooses (disk, clipboard, their own upload server).

## Language

### Capturing

**Capture**:
One screenshot or recording produced by running a Workflow, together with its file and any upload result.
_Avoid_: Shot, grab, snip

**Capture Mode**:
What a Workflow captures and how the user picks it: region, window, or full screen, as a still image or a recording.
_Avoid_: Capture type

**Freeze Frame**:
A still of the screen, cursor included, taken the moment a capture starts; interactive selection happens on the Freeze Frame instead of the live screen.
_Avoid_: Frozen screen, snapshot

**Recording**:
A Capture that is a video or GIF rather than a still image.
_Avoid_: Screencast, video capture

### Customisation

**Workflow**:
A named, hotkey-bound recipe: a Capture Mode, then After-Capture Steps, then an optional Destination, then After-Upload Steps.
_Avoid_: Profile, preset, task

**Step**:
One action in a Workflow's pipeline, e.g. save to disk, copy image, copy link, show toast. Steps run either after capture or after upload.
_Avoid_: Action, task, hook

**Destination**:
Where a Workflow uploads a Capture. Custom Destinations are defined in ShareX's `.sxcu` format.
_Avoid_: Uploader, host, service
