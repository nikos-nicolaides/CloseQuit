# CloseQuit

A tiny menu-bar utility for macOS 12+ that quits an app when you close its last window with the red ✕ button — like on Windows.

## Build & install

```bash
chmod +x build.sh
./build.sh
mv build/CloseQuit.app /Applications/
open /Applications/CloseQuit.app
```

On first launch macOS asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility). Turn CloseQuit on there; it starts working within a couple of seconds, no restart needed.

> Because the app is ad-hoc signed, Gatekeeper may block the first open. Right-click the app → **Open**, or run `xattr -dr com.apple.quarantine /Applications/CloseQuit.app`.
>
> If you rebuild, macOS treats it as a new app: remove CloseQuit from the Accessibility list with the **–** button and add it again.

## Using it

- Click the red ✕ on an app's **last** window → the app quits (normal Quit, so unsaved-changes prompts still appear).
- Closing a window while others are still open just closes that window.
- **Hold ⇧ Shift** while clicking ✕ to close the window without quitting.
- Menu bar icon (✕ in a circle):
  - **Quit Apps When Last Window Closes** — master on/off switch.
  - **Never Quit _App_** — exclude the app you were just using.
  - **Excluded Apps** — click an entry to remove it.
  - **Open at Login** (macOS 13+).

Finder, Dock and other system UI are never quit. Menu-bar-only and background apps are ignored.

## How it works

A passive event tap watches mouse clicks. On mouse-down, the Accessibility API checks whether the element under the cursor is a window close button (`AXCloseButton`). The click is never blocked; after the window closes, CloseQuit checks the app's remaining standard windows and dialogs a few times over ~1.75 s and sends a regular quit request once none remain.

## Known limitations

- The Accessibility API usually only reports windows on the **current Space**. If an app has windows on another desktop, closing its last window here may quit it. Exclude such apps if you work across multiple Spaces.
- Apps with custom-drawn title bars (some Electron apps, games) may not expose a standard close button and will behave as before.
