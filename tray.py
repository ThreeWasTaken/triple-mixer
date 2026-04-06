#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from PySide6.QtCore import QTimer, Qt, QRect
from PySide6.QtGui import QAction, QColor, QIcon, QPainter, QPen, QPixmap
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

SCRIPT_DIR = Path(__file__).resolve().parent
MIXER_CMD = str(SCRIPT_DIR / "triple-mixer.sh")
TRAY_POLL_INTERVAL_MS = int(os.environ.get("TRAY_POLL_INTERVAL_MS", "200"))


@dataclass(eq=True)
class MixerState:
    master: int = 100
    voice: int = 100
    game: int = 100
    step: int = 5
    has_voice: bool = False
    has_game: bool = False


def clamp(v):
    try:
        n = int(v)
    except Exception:
        return 0
    return max(0, min(100, n))


def run_cmd(*args):
    try:
        res = subprocess.run(
            [MIXER_CMD, *args],
            check=True,
            capture_output=True,
            text=True,
        )
        return res.stdout.strip()
    except Exception:
        return ""


def set_group(group, value):
    run_cmd("set", group, str(value))


def get_stream_flags():
    out = run_cmd("list-streams")
    has_voice = False
    has_game = False

    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue

        group = parts[1].strip()
        if group == "voice":
            has_voice = True
        elif group == "game":
            has_game = True

    return has_voice, has_game


def get_state():
    raw = run_cmd("json")
    if not raw:
        return MixerState()

    try:
        data = json.loads(raw)
    except Exception:
        return MixerState()

    has_voice, has_game = get_stream_flags()

    return MixerState(
        master=clamp(data.get("master")),
        voice=clamp(data.get("voice")),
        game=clamp(data.get("game")),
        step=clamp(data.get("step")),
        has_voice=has_voice,
        has_game=has_game,
    )


def make_icon(state):
    size = 24
    pix = QPixmap(size, size)
    pix.fill(Qt.transparent)

    p = QPainter(pix)
    p.setRenderHint(QPainter.Antialiasing, False)

    margin = 2
    gap = 2
    inner_w = size - 2 * margin
    bar_w = (inner_w - 2 * gap) // 3
    bar_h = size - 2 * margin

    master_color = QColor(240, 240, 240)
    voice_color = QColor(150, 80, 255) if state.has_voice else QColor(220, 60, 60)
    game_color = QColor(100, 230, 130) if state.has_game else QColor(220, 60, 60)

    bars = [
        (state.master, master_color),
        (state.voice, voice_color),
        (state.game, game_color),
    ]

    x = margin
    for value, color in bars:
        p.fillRect(QRect(x, margin, bar_w, bar_h), QColor(70, 70, 70))
        fill_h = round(bar_h * value / 100)
        p.fillRect(QRect(x, margin + bar_h - fill_h, bar_w, fill_h), color)
        p.setPen(QPen(QColor(40, 40, 40), 1))
        p.drawRect(QRect(x, margin, bar_w, bar_h))
        x += bar_w + gap

    p.end()
    return QIcon(pix)


def tooltip(state):
    voice_status = "ok" if state.has_voice else "absent"
    game_status = "ok" if state.has_game else "absent"

    return (
        "Triple Mixer\n"
        f"Master : {state.master}%\n"
        f"Voice  : {state.voice}% ({voice_status})\n"
        f"Game   : {state.game}% ({game_status})\n"
        "Left click: toggle voice+game 0%/100%"
    )


class Tray:
    def __init__(self):
        self.app = QApplication(sys.argv)
        self.tray = QSystemTrayIcon()
        self.last = None

        menu = QMenu()
        act_refresh = QAction("Refresh")
        act_toggle = QAction("Toggle Voice + Game 0% / 100%")
        act_quit = QAction("Quit")

        act_refresh.triggered.connect(self.force_refresh)
        act_toggle.triggered.connect(self.toggle_voice_game)
        act_quit.triggered.connect(self.app.quit)

        menu.addAction(act_refresh)
        menu.addAction(act_toggle)
        menu.addSeparator()
        menu.addAction(act_quit)

        self.tray.setContextMenu(menu)
        self.tray.activated.connect(self.on_activated)

        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(TRAY_POLL_INTERVAL_MS)

        self.force_refresh()

    def apply(self, state):
        self.tray.setIcon(make_icon(state))
        self.tray.setToolTip(tooltip(state))
        if not self.tray.isVisible():
            self.tray.show()

    def refresh(self):
        state = get_state()
        if state != self.last:
            self.last = state
            self.apply(state)

    def force_refresh(self):
        state = get_state()
        self.last = state
        self.apply(state)

    def toggle_voice_game(self):
        state = get_state()

        if state.voice == 0 and state.game == 0:
            set_group("voice", 100)
            set_group("game", 100)
        else:
            set_group("voice", 0)
            set_group("game", 0)

        self.force_refresh()

    def on_activated(self, reason):
        if reason == QSystemTrayIcon.Trigger:
            self.toggle_voice_game()

    def run(self):
        return self.app.exec()


if __name__ == "__main__":
    sys.exit(Tray().run())
