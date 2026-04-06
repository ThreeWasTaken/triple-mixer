<img width="32" height="28" alt="image" src="https://github.com/user-attachments/assets/fde0205c-08ce-455d-af20-acd43c9b01ff" />


# 🎛 triple-mixer

Advanced yet simple audio mixer for Linux (PipeWire).

Split your audio into 3 logical channels:

- ⚪ **master** → system volume (read-only)
- 🟣 **voice** → voice apps (Discord, WebRTC)
- 🟢 **game** → everything else

---

## ✨ Features

- 🎧 Separate volume control for voice and game
- 🔁 Relative volume control (preserves balance between apps)
- 🧠 Automatic app classification
- ⚡ Real-time updates via PipeWire events
- 🖱 Lightweight tray UI (Qt / PySide6)
- ⌨️ CLI-first design (scriptable)
- 🧩 No heavy dependencies, no daemon

---

## 🧠 Concept

Instead of controlling volume per-app manually:


Discord → voice channel
Browser → voice channel
Game → game channel
Music → game channel


You control:
- voice volume independently
- game volume globally but relatively

---

## 📦 Requirements

- Linux (tested on Arch + KDE + PipeWire)
- `pactl`
- `wpctl`
- Python 3
- `PySide6` (for tray)

---

## 🚀 Installation

```bash
git clone https://github.com/ThreeWasTaken/triple-mixer.git
cd triple-mixer
chmod +x init.sh
▶️ Usage
Start everything
./init.sh

This launches:

event listener (PipeWire)
tray UI
🎮 CLI
triple-mixer.sh json
triple-mixer.sh list-streams

triple-mixer.sh get master
triple-mixer.sh get voice
triple-mixer.sh get game

triple-mixer.sh up voice
triple-mixer.sh down game
triple-mixer.sh set voice 50

triple-mixer.sh normalize-game
🎛 Channels
⚪ master
reflects system volume
read-only
synced with wpctl
🟣 voice
matches voice apps (WebRTC, Discord, etc.)
applied as absolute volume
🟢 game
everything else
applied as relative delta
preserves per-app differences
🖱 Tray UI
Displays current levels
Updates automatically
Color-coded:
⚪ master
🟣 voice
🟢 game
🔴 shows error if no streams detected
⌨️ Keybindings

Example scripts:

tm-voice-up.sh
tm-voice-down.sh
tm-game-up.sh
tm-game-down.sh
tm-game-reset.sh

Bind them in KDE for quick control.

⚙️ Configuration
~/.bin/triple-mixer/triple-mixer.conf

You can configure:

app matching rules
default values
behavior tweaks
🧩 Architecture
triple-mixer/
  triple-mixer.sh      # core logic
  triple-mixer.conf    # user config
  init.sh              # entrypoint
  events.sh            # PipeWire listener
  tray.py              # UI
🔄 How it works
Uses pactl to control streams
Uses wpctl for system volume
Tracks state in:
~/.config/triple-mixer/state
Single listener prevents race conditions
⚠️ Known issues
Requires PipeWire
App detection is heuristic-based
Tray uses polling (lightweight)
🚀 Future ideas
better app classification
profiles (gaming / work / streaming)
integration with audio-output
rofi control interface
🧠 Philosophy
simple > perfect
bash + system tools
no daemon
modular design
fast and predictable
