# Dell PBP

Control your Dell UltraSharp U4025QW from the macOS menu bar. Show two computers side by side, change how much space each gets, or give one computer the whole screen. This might work with other moderl Dell monitors but is untested.

## What you need

- A Dell UltraSharp **U4025QW** monitor.
- An **Apple silicon Mac** running **macOS 13 or later**.
- A direct video connection to the monitor, with **DDC/CI** enabled in the monitor's settings.

## Install

1. Download **Dell-PBP-Apple-silicon.zip** from [GitHub Releases](https://github.com/jtreminio/dell-pbp/releases).
2. Unzip it and drag **Dell PBP.app** into **Applications**.
3. Open the app. A monitor icon appears in your menu bar at the top of the screen.
4. For the first setup, enable picture-by-picture (PBP) on the monitor so both computers are visible. The app will detect their inputs.

If macOS blocks the first launch, see [Apple's guide to opening an app from an unidentified developer](https://support.apple.com/en-us/102445).

You can enable **Launch at login** from the app's menu to keep it available after restarting your Mac.

## Updates

Choose **Check for Updates…** from the app's menu to download and install a newer version. Enable **Check for updates automatically** to have the app check for you; when one is ready, the menu shows **Update Available…**. You choose when to install it.

If your current copy has no update option, download and install the latest release once on each Mac. Future updates work inside the app.

## Use it

Click the monitor icon and choose:

- **20 / 80**, **25 / 75**, **50 / 50**, **75 / 25**, or **80 / 20** — the percentage of screen space for the left and right computers.
- **Only left input** or **Only right input** — give that computer the whole screen. Choose a split to show both again.
- **Switch Displays** — swap the left and right computers without changing the split.

Under **Inputs**, you can choose which ports belong on each side. Select a layout afterward to apply your choice.

Want recognizable names? Open **Inputs → Name inputs…**. The app automatically names the Mac it's running on; you can name the other computer yourself. Names stay with their inputs when you swap sides.

## Help prevent sleep when switching

**Install and run Dell PBP on every connected Mac if you want sleep prevention on all of them.** Keep **Wake on monitor changes** enabled on each Mac. No pairing is needed.

Changing the split briefly disconnects the display, which can make a Mac go to sleep. Each copy of the app helps its own Mac stay awake and recover when the display returns. The app must already be running before you switch.

A brief black screen during switching is normal. Sleep prevention is experimental, especially with laptop lids closed. If a Mac still sleeps, try leaving its lid open.

## Having trouble?

- **Monitor unavailable:** check the video connection and that DDC/CI is enabled, then choose **Refresh monitor**.
- **The monitor switches back to another input:** make sure the computer you selected is awake and sending video.
- **Can't return from a full-screen input:** use the app on the visible Mac, or the monitor's joystick, to enable PBP again.

Use [GitHub Issues](https://github.com/jtreminio/dell-pbp/issues) to report problems. Include your Mac model, macOS version, and what happened.

## About this project

This code is **completely vibecoded**. I don't know Swift, and I don't want to learn it. I wanted a convenient way to control my monitor, so I had AI build it. Expect rough edges.

Thanks to [m1ddc](https://github.com/waydabber/m1ddc) for the monitor-discovery code this app builds on.

Updates use [Sparkle](https://sparkle-project.org/). Building or publishing a release? See [RELEASING.md](RELEASING.md).
