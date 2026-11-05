#!/usr/bin/env python3
"""Writes script/dmg_layout.DS_Store: the Finder window of the macOS install DMG.

It is a prebuilt file because release runners have no Finder session to script.
To change the layout, edit the values here and run:

    pip install ds_store && python3 script/make_dmg_layout.py
"""

from pathlib import Path

from ds_store import DSStore

OUTPUT = Path(__file__).with_name("dmg_layout.DS_Store")

WINDOW_ORIGIN = (200, 300)
WINDOW_SIZE = (480, 280)
ICON_SIZE = 96
TEXT_SIZE = 13
ICON_POSITIONS = {
    "Whisper.app": (130, 115),
    "Applications": (350, 115),
}


def main() -> None:
    OUTPUT.unlink(missing_ok=True)
    with DSStore.open(str(OUTPUT), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = {
            "WindowBounds": "{{%d, %d}, {%d, %d}}" % (*WINDOW_ORIGIN, *WINDOW_SIZE),
            "ShowToolbar": False,
            "ShowStatusBar": False,
            "ShowPathbar": False,
            "ShowTabView": False,
            "ShowSidebar": False,
            "ContainerShowSidebar": False,
            "PreviewPaneVisibility": False,
            "SidebarWidth": 180,
        }
        store["."]["icvl"] = ("type", "icnv")
        store["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 0,
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "arrangeBy": "none",
            "showIconPreview": True,
            "showItemInfo": False,
            "labelOnBottom": True,
            "textSize": float(TEXT_SIZE),
            "iconSize": float(ICON_SIZE),
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
        }
        for name, position in ICON_POSITIONS.items():
            store[name]["Iloc"] = position


if __name__ == "__main__":
    main()
