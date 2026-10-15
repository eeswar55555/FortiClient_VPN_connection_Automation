# FortiClient SAML VPN One-Click Connector

A single Windows PowerShell script that connects to a **FortiClient SSL VPN that uses
SAML / Microsoft single sign-on**, with one double-click. It opens FortiClient, clicks
**Connect**, types your username and password into the Microsoft sign-in window, presses
Enter on "Stay signed in?", and leaves **only the phone approval (MFA) to you**.

While it runs, a small cat banner appears in the top-left corner of the screen so you know
automation is in progress. If you touch the mouse or keyboard at the wrong moment, the cat
turns angry and tells you to stop.

> **Read this first:** the script types your real password into a window, using simulated
> mouse clicks and keystrokes. Check that your organisation's IT/security policy allows
> automating VPN login and storing a password on your machine. You use this at your own risk.
> See [Security](#security).

---

## Table of contents

1. [Why this exists](#why-this-exists)
2. [What it does, step by step](#what-it-does-step-by-step)
3. [Requirements](#requirements)
4. [Installation and first-time setup](#installation-and-first-time-setup)
5. [Daily use](#daily-use)
6. [Command-line options](#command-line-options)
7. [The cat banner](#the-cat-banner)
8. [Safety features](#safety-features)
9. [Configuration reference](#configuration-reference)
10. [Files and where things are stored](#files-and-where-things-are-stored)
11. [Troubleshooting](#troubleshooting)
12. [Security](#security)
13. [Known limitations](#known-limitations)
14. [How it works internally](#how-it-works-internally)

---

## Why this exists

Newer FortiClient versions (tested on **7.4.3**) are an Electron app. Their buttons are not
exposed to Windows UI Automation, there is no command-line option to connect, and the SAML
sign-in is a separate window. The only reliable way to automate the login is to act like a
person: click on screen and type. This script does that, but carefully, so it never types
credentials into the wrong window and never fights with you for the keyboard.

## What it does, step by step

1. Starts FortiClient (if it is not already running) and puts its window at the position
   you recorded during setup.
2. Waits until you have your hands off the mouse and keyboard, then clicks **Connect**
   (and any other buttons you recorded, in order).
3. Waits for the **"FortiClient SAML Authentication"** window (the Microsoft sign-in) and for
   its page to finish loading. The FortiClient main window is minimised so it does not get in
   the way.
4. Brings the sign-in window to the front, **verifies it really is in front**, and types your
   username and Enter, then your password and Enter.
5. **You approve the sign-in on your phone.** The cat tells you when.
6. Presses Enter every few seconds on the sign-in window ("Stay signed in?") until the VPN
   tunnel comes up, then closes the leftover windows and FortiClient.
7. Exits. No console window, no background process, no timer is left running.

## Requirements

- Windows 10 / 11 with **Windows PowerShell 5.1** (built in). PowerShell 7 is not needed.
- **FortiClient 7.x** installed at `C:\Program Files\Fortinet\FortiClient\FortiClient.exe`.
  Tested on 7.4.3. If yours is elsewhere, edit `$FortiExe` at the top of the script.
- A VPN profile that uses **SAML / Microsoft sign-in** and a phone-based approval (push
  notification). Pure username-and-password VPNs do not need this script.
- No administrator rights are needed.

## Installation and first-time setup

1. Copy `Connect-VPN.ps1` anywhere you like, for example `C:\Tools\VpnConnector\`.
2. Open **FortiClient** and go to the VPN page. Make sure your VPN profile is selected and the
   **Connect** button is visible.
3. Arrange two windows side by side: **PowerShell on the left half**, **FortiClient on the
   right half**. Put FortiClient where you want it to appear every time and do not resize it
   afterwards.
4. In the PowerShell window, run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "C:\Tools\VpnConnector\Connect-VPN.ps1" -Setup
   ```

5. Answer the prompts:
   - **Username** - your sign-in name, for example `you@company.com`. Type it and press Enter.
   - **Password** - typing is hidden. Press Enter. It is stored encrypted (see
     [Security](#security)).
   - **Press Enter when FortiClient is ready** - click in PowerShell and press Enter. This
     records the FortiClient window position and size.
   - **Hover the mouse over click #1, then press Enter here** - move the mouse onto the
     **Connect** button (do not click), and without moving it press **Enter** on the
     keyboard. The script reads the mouse position at that moment. If you must click other
     things first (for example a VPN drop-down and then your VPN name), record them in order,
     with Connect last.
   - Type `d` and press Enter when you have recorded all clicks.
6. Setup ends by creating:
   - `Connect-VPN.vbs` next to the script (a tiny launcher that runs the script with no
     visible console window), and
   - a **Connect VPN** shortcut on your Desktop.

   You can pin the shortcut to the taskbar or Start menu, or give it a keyboard shortcut in
   its Properties.

Optional: run a dry run (below) to check everything works before the first real login.

## Daily use

1. Make sure the VPN is disconnected (if it is already connected, the script just exits).
2. Double-click **Connect VPN**.
3. **Take your hands off the mouse and keyboard** and watch the cat in the top-left corner.
4. When the cat says **"Approve the sign-in on your phone"**, approve it.
5. When the cat says **"VPN connected!"**, you are done.

Press **Esc** at any time to cancel.

## Command-line options

Run these with
`powershell -ExecutionPolicy Bypass -File Connect-VPN.ps1 <option>`:

| Option | What it does |
|---|---|
| *(none)* | Normal login. This is what the Desktop shortcut runs. |
| `-Setup` | First-time setup: username, password, FortiClient window position, click positions, shortcut. Safe to re-run to re-record clicks. |
| `-SetCredentials` | Change **only** the username/password. Asks for the password twice and checks they match. Keeps your click positions. |
| `-DryRun` | Does everything up to the moment of typing, confirms the sign-in window is in front, then stops **without typing anything**. Use it to test after setup or after a FortiClient update. |

## The cat banner

A small banner in the top-left corner of the primary screen. It never takes keyboard focus
and mouse clicks pass through it.

| Cat | Meaning |
|---|---|
| Calm cat, blue | Automation is running. Hands off, please. |
| Angry cat, red | You touched the mouse or keyboard while it was running. Stop. |
| Cat with phone message, green | Approve the sign-in on your phone now. |
| Happy cat | VPN connected (or dry run finished). |
| Shocked cat | An error occurred. The message is shown for about 8 seconds, then the banner closes. |

The cats are drawn in code. To use your own images (for example memes), put PNG files named
`working.png`, `angry.png`, `phone.png`, `happy.png` and `error.png` in
`%LOCALAPPDATA%\VpnConnector\cats\`. Any file that exists replaces the drawing for that
state.

## Safety features

Typing a password into the wrong window would be bad, so the script is defensive:

- **Front-window check.** Before every key it sends, it brings the target window to the front
  and confirms that window really is in front **and** belongs to an allowed program
  (`FortiClient`, `FortiAuth`, `msedgewebview2`). Otherwise it stops with nothing typed. If
  you click another app (a browser, chat, editor), nothing is typed there.
- **Wait for quiet.** Before every click or typing step it waits until you have had your hands
  off the mouse and keyboard for about 1.2 seconds (holding Shift, Ctrl, Alt or Win counts as
  touching). If you keep using the machine for 40 seconds it gives up without typing.
- **Input lock while typing.** For a few seconds around each click and each typing step,
  your *physical* keyboard and mouse input is swallowed, so a stray key cannot end up in the
  password box. The lock expires on its own, so it can never leave you stuck, and it ends
  immediately when the script ends. Ctrl+Alt+Del always works.
- **It can tell you from itself.** A low-level hook distinguishes real input from the
  script's own injected input, so the script never mistakes itself for you.
- **Esc cancels** the run.
- **Layout-independent typing.** Text is sent as Unicode characters, not key presses, so
  Caps Lock, Num Lock and the keyboard layout cannot change what is typed. Special
  characters such as `@ { } + ^ % ~ ( ) [ ] "` are typed exactly.
- **Never types into the login window blindly.** It waits for the page title to show the
  Microsoft page has loaded before typing.
- **Clean exit.** Leftover sign-in windows are closed, and FortiClient is closed once the
  tunnel is confirmed up.

## Configuration reference

Settings live in `%LOCALAPPDATA%\VpnConnector\config.json`. Edit it with any text editor.
Most people never need to.

| Key | Default | Meaning |
|---|---|---|
| `Username` | (from setup) | Sign-in name typed into the Microsoft page. Change with `-SetCredentials`. |
| `Window` | (from setup) | FortiClient window `X`, `Y`, `W`, `H` in screen pixels. |
| `Clicks` | (from setup) | List of clicks as offsets `DX`, `DY` from the window's top-left, with `DelayAfterSec` after each. |
| `LoginPageWaitSec` | `2` | Extra wait after the Microsoft page has loaded, before typing the username. |
| `PasswordWaitSec` | `4` | Wait between the username and the password. Increase if the password page loads slowly. |
| `FirstEnterAfterSec` | `8` | Wait after the password before the first Enter on "Stay signed in?". |
| `EnterEverySec` | `4` | How often Enter is pressed while waiting for the VPN to connect. |
| `TimeoutSec` | `150` | Give up if the VPN is not up after this long. |
| `MinimizeFortiWindow` | `true` | Minimise FortiClient while the Microsoft window is open. **Do not close it then:** FortiClient must stay running to receive the sign-in result. |
| `CloseFortiWhenDone` | `true` | Close FortiClient after the VPN is up (and verify the tunnel stays up). Set to `false` if closing it drops your VPN. |

## Files and where things are stored

In the repository:

| File | Purpose |
|---|---|
| `Connect-VPN.ps1` | The whole tool: setup, login, input guard, cat banner. |
| `README.md` | This document. |
| `.gitignore` | Keeps generated and personal files out of git. |

Created on your machine, **never** inside the repository:

| Path | Contents |
|---|---|
| `%LOCALAPPDATA%\VpnConnector\config.json` | Username, window position, click offsets, timings. No password. |
| `%LOCALAPPDATA%\VpnConnector\password.dat` | Your password, encrypted with Windows DPAPI. |
| `%LOCALAPPDATA%\VpnConnector\last-run.log` | Log of the most recent run (window names and steps, never credentials). |
| `%LOCALAPPDATA%\VpnConnector\cats\` | Optional custom cat images. |
| `Connect-VPN.vbs` (next to the script) | Hidden-window launcher, generated by `-Setup`. Contains a local path, so it is git-ignored. |
| Desktop `Connect VPN.lnk` | The shortcut you double-click. |

## Troubleshooting

First look at `%LOCALAPPDATA%\VpnConnector\last-run.log`. Every step is timestamped, and
any new window it saw is listed with its program, size and title.

| Symptom | Likely cause and fix |
|---|---|
| Typing starts too early (nothing in the box) or the password is typed into the username field | Increase `LoginPageWaitSec` / `PasswordWaitSec` in `config.json` by 2-3 seconds. |
| It clicked the wrong place | The FortiClient window moved or was resized, or the layout changed. Run `-Setup` again. |
| "Could not bring the sign-in window to the front... Nothing was typed" | Something else grabbed focus (a notification, another app). Run again and keep your hands off. |
| "Refusing to type: front window belongs to '...'" | The wrong program was in front. This is the safety check working. Run again. |
| "You kept using the mouse/keyboard..." | You touched something for 40 seconds. Run again and leave it alone. |
| "The sign-in finished or was closed, but the VPN did not connect" | The Microsoft window closed (you cancelled, the approval was denied or timed out). Run again. |
| "Closing FortiClient dropped the VPN" | Set `"CloseFortiWhenDone": false` in `config.json`. |
| Microsoft login shows a wrong-password error | Run `-SetCredentials`. Do not retry repeatedly or your account may lock. |
| FortiClient shows "A JavaScript error occurred in the main process ... guimessenger64.node ... module could not be found" | FortiClient was started from the wrong working directory. Its shortcut starts it in `C:\Program Files\Fortinet\FortiClient\`. The script already does this. If you start it yourself, do the same, for example `Start-Process FortiClient.exe -WorkingDirectory "C:\Program Files\Fortinet\FortiClient"`. |
| After a FortiClient update nothing works | Run `-DryRun` and read the log. The sign-in window title (`FortiClient SAML Authentication`) and process name (`FortiAuth`) are hard-coded near the top of the script and may have changed in your version. |

## Security

- **Your password is stored encrypted with Windows DPAPI** (`ConvertFrom-SecureString`
  without a key). Only **your Windows account on this PC** can decrypt it. Copying
  `password.dat` to another PC or user will not work. It is stored in
  `%LOCALAPPDATA%`, **outside** the repository.
- Anyone who can run code **as you** on your PC can decrypt it. This is the same trust level
  as your browser's saved passwords. Use full-disk encryption and lock your screen.
- The password exists in plain text in memory only for the few seconds it takes to type it,
  and is cleared afterwards.
- It is typed with simulated keystrokes. It is never written to the log, never put on the
  clipboard and never sent anywhere. The script makes **no network connections** of its own.
- **Never paste your password into a chat, an issue or a commit.** If you ever do, change it.
- The script installs temporary low-level keyboard and mouse hooks **only while it runs** and
  only to tell your input from its own and to swallow stray input for a few seconds. It does
  not record what you type. Some antivirus tools may flag any program that installs such
  hooks. The source is a single readable file so you can check it.
- It does **not** bypass or weaken MFA: the phone approval is still done by you.
- Check your employer's policy before using it.

## Known limitations

- **Windows only**, and tested only with FortiClient 7.4.3 and a Microsoft SAML sign-in.
- It depends on screen positions, so changes to the FortiClient layout, the screen
  resolution, the display scaling or the window size mean re-running `-Setup`.
- It assumes the Microsoft sign-in is the standard username, then password, then phone
  approval, then "Stay signed in?" flow. Other flows (for example number matching that needs
  typing a code, or a different identity provider) need script changes.
- Only the primary screen is used for the cat banner.
- You must not use the mouse or keyboard during the roughly 30-60 seconds the script runs
  (this is by design, and Esc cancels).
- It cannot tell whether a password is wrong. It only sees that the VPN did not connect.

## How it works internally

For anyone who wants to read or change the code. Everything is in `Connect-VPN.ps1`:

- **Window handling (Win32 via `Add-Type`)**: enumerate windows, find the FortiClient main
  window and the `FortiClient SAML Authentication` window by title and owning process, move
  and minimise windows, and bring a window to the front without a fake Alt key press (which
  would open the window menu and swallow the first typed character).
- **`InputGuard` (C#)**: installs low-level keyboard and mouse hooks on the banner's UI
  thread. It checks the *injected* flag to separate human from script input, can swallow human
  input for a limited time (self-expiring), and flags the Esc key.
- **`Typer` (C#)**: sends characters with `SendInput` using `KEYEVENTF_UNICODE`, so the result
  does not depend on layout or Caps Lock.
- **`CatOverlay` (C#, WinForms)**: borderless, topmost, non-activating, click-through banner
  with a cat drawn using GDI+; scales with Windows display scaling; optional PNG overrides.
- **Flow control (PowerShell)**: `Wait-Quiet` -> lock input -> `Assert-Foreground` -> act ->
  unlock, for each critical step. The VPN-up check looks at the status of the
  *Fortinet SSL VPN Virtual Ethernet Adapter*.
- **Setup**: `-Setup` stores your DPAPI-encrypted password and a JSON config, and creates the
  launcher and shortcut.

If you adapt it to a different FortiClient version or identity provider, the places to look
are `$AllowedProcesses`, the `FortiClient SAML Authentication` title match, and the
page-ready check (the `[Sign in` title test) in the run section.
