# indieshelf

A tiny drag-and-drop shelf that lives in your Mac's menu bar. Start dragging some files, **shake the cursor**,
and the shelf drops down. Put the files on it, go wherever you need to go, and drag them back out. They stay on
the shelf until you remove them, and the menu bar icon shows how many are there.

- One Swift file, AppKit only. No dependencies, no Xcode project.
- Under 500 KB, one binary for Apple Silicon and Intel. Lives in the menu bar, no Dock icon.
- Default macOS look. No settings, no accounts, no network.

## Install

indieshelf needs **macOS 14 (Sonoma) or newer**, on Apple Silicon or Intel.

### Option 1: build it yourself (recommended)

This takes about a minute, and macOS won't complain about an app you built yourself.

1. Install Apple's command line tools if you don't have them (it's free, and nothing else is needed):
   ```sh
   xcode-select --install
   ```
2. Get the code and build it:
   ```sh
   git clone https://github.com/tetzgabriel/indieshelf.git
   cd indieshelf
   ./build.sh
   ```
3. Move it to Applications and open it:
   ```sh
   mv indieshelf.app /Applications/
   open /Applications/indieshelf.app
   ```

A tray icon appears in the menu bar. That's indieshelf.

### Option 2: download the app

1. Download `indieshelf.zip` from the [Releases page](https://github.com/tetzgabriel/indieshelf/releases) and double-click it to unzip.
2. Drag `indieshelf.app` into your **Applications** folder.
3. Open it. macOS will say it **"cannot be opened"** or **"could not verify"** it. That's expected: indieshelf is free
   and isn't registered with Apple's paid developer program, so Apple has never checked it. Click **Done**.
4. Go to **System Settings → Privacy & Security**, scroll down to the message about indieshelf, and click
   **Open Anyway**. Confirm with your password.

You only do this once. If you'd rather not trust a downloaded app, use Option 1: you can read every line
in [`main.swift`](main.swift) before building it.

### Start it at login

**System Settings → General → Login Items → +**, then pick indieshelf from Applications.

### Uninstall

Click the tray icon, click **Quit**, and drag `indieshelf.app` to the Trash. The only other trace is a small
preferences file at `~/Library/Preferences/io.github.tetzgabriel.indieshelf.plist`, which holds the list of what's on
your shelf. Delete it too if you want a clean slate.

## Use

The shelf lives behind the **tray icon** in the menu bar. The little tag on it shows how many items are there.

- **Put files on it:** start dragging files and shake the cursor, and the shelf drops down; drop them on it. Or drop
  them straight onto the tray icon. Or click the icon and drop them in the window.
- **Take files off:** drag them out of the list, one or several at a time. Drag the big icon at the top to take
  everything at once. It works like a normal Finder drag: move on the same disk, copy to another one, hold ⌥ to
  copy.
- **They stay** until you remove them, even after a restart. If a file gets moved or renamed, the shelf follows
  it. Files that end up in the Trash disappear from the shelf.
- **Remove from Shelf** (right-click, or select and press Delete) and **Clear All** only take items off the
  shelf. Clear All also closes it. Your files are never deleted, copied or changed: the shelf only remembers where they are.
- Double-click to open a file. Right-click for **Show in Finder**. Esc or a click anywhere else closes the shelf.
- In full-screen apps and Mission Control, where the menu bar is hidden, a shake opens the shelf right at the
  cursor instead.

## If the shake doesn't work

Run it from Terminal with logging on:

```sh
INDIESHELF_DEBUG=1 ./indieshelf.app/Contents/MacOS/indieshelf
```

Drag a file and shake. You should see `reversal 1`, `reversal 2`, … then `shake`. If you see
`shake ignored: not dragging files`, the shake was fine but macOS didn't report a file drag (dragging text or
a link is deliberately ignored). The thresholds
are at the top of `ShakeDetector` in `main.swift`.

## Making a release

```sh
./build.sh
ditto -c -k --keepParent indieshelf.app indieshelf.zip
```

Upload `indieshelf.zip` to a new GitHub release. (`ditto` keeps the app's signature intact; Finder's
"Compress" works too.)

## License

MIT
