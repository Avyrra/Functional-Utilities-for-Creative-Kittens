pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import QtQuick

// Pure black overlay to rest OLED pixels. Not a lock screen, not DPMS.
Scope {
	id: root

	// ── Tunables ─────────────────────────────────────────────────
	property int  idleTimeout:      270
	property int  dimGraceSeconds:  30
	property color dimColor:        Qt.rgba(0.07, 0.03, 0.0, 0.35)
	property int  fadeMs:           1200
	property int  manualFadeMs:     300

	property int  idleDeadZone:     10

	property real motionDeadZone:   3
	property real dismissMotionPixels: 120
	property real motionDecay:      0.9
	property int  motionDrainMs:    30

	// libinput sees the keybind that summoned us
	property int  armDelayMs:       600

	property bool manageCursor:      true
	// Jitter re-shows the cursor, so hide the mice from Hyprland while we're up
	property bool disablePointerWhileActive: true
	// Hyprland has no "hide now" and 0 means never, so use the smallest float that takes
	property real cursorHideSeconds: 0.1
	// Mapping over the cursor un-hides it, so nudge after the overlay is up
	property int  cursorApplyDelayMs: 100

	// ── Live state ───────────────────────────────────────────────
	property bool overlayActive:       false  // dimmed or black
	property bool fullyBlack:          false  // false = dimmed, true = black
	property bool manualActivation:    false  // this activation came from IPC
	property bool libinputUnavailable: false  // true → running on the fallback
	property bool armed:               false  // dismissal input is being honoured
	property int  idleElapsed:         0      // seconds toward idleTimeout
	property real netDx:               0      // mouse travel this second
	property real netDy:               0
	property real motionEnergy:        0      // dismissal leaky bucket
	property real lastMouseX:          0
	property real lastMouseY:          0
	property bool hasMouseBaseline:    false

	property var  pointerDeviceNames:  []
	property real savedCursorTimeout:  0
	property bool cursorTimeoutSaved:  false
	property bool cursorOverridden:    false

	// Stands in for "a video is playing, don't blank the screen"
	readonly property bool mediaIsPlaying:
		(Mpris.players?.values ?? []).some(p => p?.isPlaying === true)

	// Holds the screen awake, but only while its workspace is on-screen
	readonly property bool fullscreenWindowVisible:
		(Hyprland.workspaces?.values ?? []).some(w => w?.active === true && w?.hasFullscreen === true)

	// A layershell can't take a grab off a window holding the mouse (Hyprland#4968)
	readonly property bool grabInput:
		root.overlayActive && (root.libinputUnavailable || !root.fullscreenWindowVisible)

	// Manual trigger goes straight to full black, with its own fade timing
	function activate(manual: bool): void {
		if (root.overlayActive) return;

		root.manualActivation = manual;
		root.motionEnergy = 0;
		root.hasMouseBaseline = false;
		root.armed = false;
		root.fullyBlack = manual;
		root.overlayActive = true;

		if (!manual) graceTimer.restart();
		armTimer.restart();
		if (root.manageCursor) cursorApplyTimer.restart();
	}

	function show(): void { root.activate(true); }

	function hide(): void {
		graceTimer.stop();
		armTimer.stop();
		root.restoreSystemCursor();

		root.overlayActive = false;
		root.fullyBlack = false;
		root.manualActivation = false;
		root.armed = false;
		root.idleElapsed = 0;
		root.netDx = 0;
		root.netDy = 0;
		root.motionEnergy = 0;
		root.hasMouseBaseline = false;
	}

	function toggle(): void {
		if (root.overlayActive) root.hide();
		else root.show();
	}

	readonly property var pointerMotionPattern: /(-?\d+\.\d+)\/\s*(-?\d+\.\d+)/

	// Accumulate motion so jitter cancels directionally; anything else is activity
	function inputLineReceived(line: string): void {
		if (root.overlayActive) {
			root.dismissLineReceived(line);
			return;
		}

		if (root.fullscreenWindowVisible) return;  // already held; don't parse

		if (line.includes("POINTER_MOTION") && !line.includes("ABSOLUTE")) {
			const delta = line.match(root.pointerMotionPattern);
			if (delta) {
				root.netDx += parseFloat(delta[1]);
				root.netDy += parseFloat(delta[2]);
			}
			return;
		}

		if (line.includes("KEYBOARD_KEY")
			|| line.includes("POINTER_BUTTON")
			|| line.includes("POINTER_SCROLL")
			|| line.includes("POINTER_AXIS")
			|| line.includes("POINTER_MOTION_ABSOLUTE")
			|| line.includes("TOUCH")
			|| line.includes("GESTURE")
			|| line.includes("TABLET"))
			root.idleElapsed = 0;
	}

	// The only wake path that survives a game's pointer grab
	function dismissLineReceived(line: string): void {
		if (!root.armed) return;

		if (line.includes("POINTER_MOTION") && !line.includes("ABSOLUTE")) {
			const delta = line.match(root.pointerMotionPattern);
			if (!delta) return;

			const dist = Math.hypot(parseFloat(delta[1]), parseFloat(delta[2]));
			if (dist < root.motionDeadZone) return;  // ignore per-event jitter

			root.motionEnergy += dist;
			if (root.motionEnergy >= root.dismissMotionPixels) root.hide();
			return;
		}

		if (line.includes("KEYBOARD_KEY") || line.includes("POINTER_BUTTON")) {
			if (line.includes("pressed")) root.hide();  // releases would wake on keybind letting-go
			return;
		}

		if (line.includes("POINTER_MOTION_ABSOLUTE")
			|| line.includes("POINTER_SCROLL")
			|| line.includes("POINTER_AXIS")
			|| line.includes("TOUCH_DOWN")
			|| line.includes("GESTURE")
			|| line.includes("TABLET"))
			root.hide();
	}

	// Nearly always a missing 'input' group
	function inputErrorReceived(line: string): void {
		if (root.libinputUnavailable) return;

		const err = line.toLowerCase();
		if (!err.includes("permission denied")
			&& !err.includes("failed to open")
			&& !err.includes("not permitted")) return;

		root.libinputUnavailable = true;
		libinputProcess.running = false;
		console.warn("[screensaver] Cannot read libinput events - jitter-proof idle detection is DISABLED,");
		console.warn("[screensaver] and waking from inside a game that grabs the mouse will NOT work.");
		console.warn("[screensaver] Add your user to the 'input' group to enable it:");
		console.warn("[screensaver]     sudo usermod -aG input $USER   (then log out and back in)");
		console.warn("[screensaver] Falling back to IdleMonitor: still works, but mouse jitter can delay activation.");
	}

	// A game's own cursor draws above every layer surface, so hide it compositor-side
	function cursorSetCommand(value: real, pointersOn: bool): var {
		let lua = "";

		if (root.disablePointerWhileActive && root.pointerDeviceNames.length > 0)
			lua += root.pointerDeviceNames
				.map(n => "hl.device({ name = \"" + n + "\", enabled = " + (pointersOn ? "true" : "false") + " })")
				.join("; ") + "; ";

		lua += "hl.config({ cursor = { inactive_timeout = " + value + " } }); "
			+ "local p = hl.get_cursor_pos(); "
			+ "hl.dispatch(hl.dsp.cursor.move({ x = 0, y = 0 })); "
			+ "local q = hl.get_cursor_pos(); "
			+ "if q.x ~= p.x or q.y ~= p.y then hl.dispatch(hl.dsp.cursor.move({ x = p.x, y = p.y })) end";

		return ["hyprctl", "eval", lua];
	}

	function hideSystemCursor(): void {
		if (!root.manageCursor || !root.overlayActive) return;
		if (!root.cursorTimeoutSaved || root.cursorOverridden) return;
		if (root.savedCursorTimeout > 0 && root.savedCursorTimeout <= root.cursorHideSeconds) return;

		root.cursorOverridden = true;
		cursorWriteProcess.exec(root.cursorSetCommand(root.cursorHideSeconds, false));
	}

	function restoreSystemCursor(): void {
		cursorApplyTimer.stop();
		if (!root.cursorOverridden) return;

		root.cursorOverridden = false;
		cursorWriteProcess.exec(root.cursorSetCommand(root.savedCursorTimeout, true));
	}

	// Manual control, e.g. a Hyprland bind: qs ipc call screensaver toggle
	IpcHandler {
		target: "screensaver"
		function toggle(): void { root.toggle(); }
		function show(): void { root.show(); }
		function hide(): void { root.hide(); }
	}

	// Raw input stream — jitter-proof because we filter it ourselves
	Process {
		id: libinputProcess
		running: true
		command: ["stdbuf", "-oL", "libinput", "debug-events"]
		onRunningChanged: if (!running && !root.libinputUnavailable) libinputRespawnTimer.start()
		stdout: SplitParser { onRead: line => root.inputLineReceived(line) }
		stderr: SplitParser { onRead: line => root.inputErrorReceived(line) }
	}

	// Recover from a crash, delayed so a hard failure can't hot-loop
	Timer {
		id: libinputRespawnTimer
		interval: 2000
		onTriggered: if (!root.libinputUnavailable) libinputProcess.running = true
	}

	// Remember the existing setting so it can be handed back intact
	Process {
		id: cursorQueryProcess
		running: root.manageCursor
		command: ["hyprctl", "-j", "getoption", "cursor.inactive_timeout"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const opt = JSON.parse(this.text);
					root.savedCursorTimeout = opt.float ?? opt.int ?? 0;
					root.cursorTimeoutSaved = true;
				} catch (e) {
					console.warn("[screensaver] Couldn't read cursor.inactive_timeout - cursor hiding is DISABLED.");
					console.warn("[screensaver] A game's own cursor may still be drawn over the overlay.");
				}
			}
		}
	}

	// hyprctl answers "ok" or a lua error; a silent failure here is the hard one to spot
	Process {
		id: cursorWriteProcess
		stdout: StdioCollector {
			onStreamFinished: if (this.text.trim() !== "ok") console.warn("[screensaver] cursor eval: " + this.text.trim())
		}
	}

	Timer {
		id: cursorApplyTimer
		interval: root.cursorApplyDelayMs
		onTriggered: deviceQueryProcess.exec(["hyprctl", "-j", "devices"])
	}

	// Re-read every activation rather than caching, so hotplugged mice aren't missed
	Process {
		id: deviceQueryProcess
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.pointerDeviceNames = (JSON.parse(this.text).mice ?? []).map(m => m.name).filter(n => !!n);
				} catch (e) {
					root.pointerDeviceNames = [];
					console.warn("[screensaver] Couldn't list mice - jitter will keep un-hiding the cursor.");
				}
				root.hideSystemCursor();
			}
		}
	}

	// Don't leave the override behind if quickshell dies while active
	Component.onDestruction: {
		if (!root.cursorOverridden) return;
		try {
			Quickshell.execDetached(root.cursorSetCommand(root.savedCursorTimeout, true));
		} catch (e) {
		}
	}

	// Idle clock. Movement, media, or a visible fullscreen window each reset it
	Timer {
		interval: 1000
		repeat: true
		running: !root.libinputUnavailable
		onTriggered: {
			const moved = Math.hypot(root.netDx, root.netDy);
			root.netDx = 0;
			root.netDy = 0;

			if (root.overlayActive) return;

			if (moved >= root.idleDeadZone || root.mediaIsPlaying || root.fullscreenWindowVisible) {
				root.idleElapsed = 0;
				return;
			}

			root.idleElapsed += 1;
			if (root.idleElapsed >= root.idleTimeout) root.activate(false);
		}
	}

	// Dimmed → black, dimGraceSeconds after an idle activation
	Timer {
		id: graceTimer
		interval: root.dimGraceSeconds * 1000
		onTriggered: root.fullyBlack = true
	}

	Timer {
		id: armTimer
		interval: root.armDelayMs
		onTriggered: root.armed = true
	}

	// Fallback when libinput is unreadable: mouse jitter resets it
	IdleMonitor {
		timeout: root.idleTimeout
		onIsIdleChanged: if (isIdle && root.libinputUnavailable && !root.overlayActive) root.activate(false)
	}

	// Bleed off dismissal-motion so only a sustained deliberate move crosses
	Timer {
		interval: root.motionDrainMs
		repeat: true
		running: root.overlayActive
		onTriggered: root.motionEnergy *= root.motionDecay
	}

	// A tinted, everything-covering overlay per monitor
	Variants {
		model: Quickshell.screens

		// qmllint disable uncreatable-type
		PanelWindow {
			id: win
			required property ShellScreen modelData
			screen: modelData

			// Nothing clickable, for when the overlay is only a black rectangle
			property var passthroughMask: Region {}

			// Mapped only while active, so dismissal removes it instantly
			visible: root.overlayActive
			focusable: root.grabInput
			mask: root.grabInput ? null : win.passthroughMask
			color: "transparent"
			WlrLayershell.layer: WlrLayer.Overlay
			WlrLayershell.keyboardFocus: root.grabInput ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
			WlrLayershell.namespace: "quickshell-screensaver"
			exclusionMode: ExclusionMode.Ignore
			anchors { top: true; bottom: true; left: true; right: true }

			Rectangle {
				id: tint
				anchors.fill: parent
				color: root.overlayActive ? (root.fullyBlack ? "black" : root.dimColor) : "transparent"
				Behavior on color {
					ColorAnimation {
						duration: root.manualActivation ? root.manualFadeMs : root.fadeMs
						easing.type: Easing.InOutQuad
					}
				}
			}

			// Swallows the input that woke it, where the compositor lets us
			Item {
				anchors.fill: parent
				focus: true
				enabled: root.grabInput

				Keys.onPressed: () => { if (root.armed) root.hide(); }

				MouseArea {
					id: dismissArea
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.BlankCursor  // no pointer over the overlay
					acceptedButtons: Qt.AllButtons

					onPressed: () => { if (root.armed) root.hide(); }
					onWheel: () => { if (root.armed) root.hide(); }

					// Fresh reference so crossing screens isn't one huge jump
					onEntered: root.hasMouseBaseline = false

					onPositionChanged: (mouse) => {
						if (!root.armed) return;

						if (!root.hasMouseBaseline) {
							root.lastMouseX = mouse.x;
							root.lastMouseY = mouse.y;
							root.hasMouseBaseline = true;
							return;
						}

						const dist = Math.hypot(mouse.x - root.lastMouseX, mouse.y - root.lastMouseY);
						root.lastMouseX = mouse.x;
						root.lastMouseY = mouse.y;

						if (dist < root.motionDeadZone) return;  // ignore per-event jitter
						root.motionEnergy += dist;

						if (root.motionEnergy >= root.dismissMotionPixels) root.hide();
					}
				}
			}
		}
	}
}