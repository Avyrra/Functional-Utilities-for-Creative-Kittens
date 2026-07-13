pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import QtQuick

Scope {
	id: root

	// ── Tunables ─────────────────────────────────────────────────
	property int  idleTimeout:      270
	property int  dimGraceSeconds:  30
	property color dimColor:        Qt.rgba(0.07, 0.03, 0.0, 0.25)
	property int  fadeMs:           1200
	property int  manualFadeMs:     300

	property int  idleDeadZone:     10

	property real motionDeadZone:   3
	property real motionThreshold:  0.06
	property real motionDecay:      0.9
	property int  motionDrainMs:    30

	// ── Live state ───────────────────────────────────────────────
	property bool overlayActive:       false  // dimmed or black, interactive
	property bool fullyBlack:          false  // false = dimmed, true = black
	property bool manualActivation:    false  // this activation came from IPC
	property bool libinputUnavailable: false  // true → running on the fallback
	property int  idleElapsed:         0       // seconds toward idleTimeout
	property real netDx:               0       // mouse travel this second
	property real netDy:               0
	property real motionEnergy:        0       // dismissal leaky bucket
	property real lastMouseX:          0
	property real lastMouseY:          0
	property bool hasMouseBaseline:    false

	// The libinput tap can't see Wayland idle inhibitors, so MPRIS playback
	// stands in for "a video is playing, don't blank the screen".
	readonly property bool mediaIsPlaying:
		(Mpris.players?.values ?? []).some(p => p?.isPlaying === true)

	// A fullscreen app should hold the screen awake, but only while its
	// workspace is actually on-screen — one you've switched away from
	// shouldn't. Cached so the input parser can skip work while gaming.
	readonly property bool fullscreenWindowVisible:
		(Hyprland.workspaces?.values ?? []).some(w => w?.active === true && w?.hasFullscreen === true)

	// Manual trigger goes straight to full black, with its own fade timing.
	function show(): void {
		root.manualActivation = true;
		root.motionEnergy = 0;
		root.hasMouseBaseline = false;
		root.fullyBlack = true;
		root.overlayActive = true;
	}

	function hide(): void {
		root.overlayActive = false;
		root.fullyBlack = false;
		root.manualActivation = false;
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

	// A discrete input event happened — restart the idle countdown.
	function registerActivity(): void {
		root.idleElapsed = 0;
	}

	readonly property var pointerMotionPattern: /(-?\d+\.\d+)\/\s*(-?\d+\.\d+)/

	// libinput emits one event per line. Motion deltas accumulate so jitter
	// cancels directionally; any other event type is unambiguous activity.
	function inputLineReceived(line: string): void {
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
			root.registerActivity();
	}

	// libinput can't open the devices — nearly always a missing 'input'
	// group. Drop to the fallback and say exactly how to fix it.
	function inputErrorReceived(line: string): void {
		if (root.libinputUnavailable) return;

		const err = line.toLowerCase();
		if (!err.includes("permission denied")
			&& !err.includes("failed to open")
			&& !err.includes("not permitted")) return;

		root.libinputUnavailable = true;
		libinputProcess.running = false;
		console.warn("[screensaver] Cannot read libinput events - jitter-proof idle detection is DISABLED.");
		console.warn("[screensaver] Add your user to the 'input' group to enable it:");
		console.warn("[screensaver]     sudo usermod -aG input $USER   (then log out and back in)");
		console.warn("[screensaver] Falling back to IdleMonitor: still works, but mouse jitter can delay activation.");
	}

	// Manual control, e.g. a Hyprland bind: qs ipc call screensaver toggle
	IpcHandler {
		target: "screensaver"
		function toggle(): void { root.toggle(); }
		function show(): void { root.show(); }
		function hide(): void { root.hide(); }
	}

	// Raw input stream — jitter-proof because we filter it ourselves.
	// stdbuf keeps it line-buffered so events don't sit in a pipe buffer.
	Process {
		id: libinputProcess
		running: true
		command: ["stdbuf", "-oL", "libinput", "debug-events"]
		onRunningChanged: if (!running && !root.libinputUnavailable) libinputRespawnTimer.start()
		stdout: SplitParser { onRead: line => root.inputLineReceived(line) }
		stderr: SplitParser { onRead: line => root.inputErrorReceived(line) }
	}

	// Recover from a crash, delayed so a hard failure can't hot-loop.
	Timer {
		id: libinputRespawnTimer
		interval: 2000
		onTriggered: if (!root.libinputUnavailable) libinputProcess.running = true
	}

	// Idle clock. Real movement, media, or a visible fullscreen window each
	// reset it. Otherwise: dimmed warning at idleTimeout, full black after
	// dimGraceSeconds more.
	Timer {
		interval: 1000
		repeat: true
		running: !root.libinputUnavailable
		onTriggered: {
			const moved = Math.hypot(root.netDx, root.netDy);
			root.netDx = 0;
			root.netDy = 0;

			if (moved >= root.idleDeadZone || root.mediaIsPlaying || root.fullscreenWindowVisible) {
				root.idleElapsed = 0;
				return;
			}

			root.idleElapsed += 1;

			if (!root.overlayActive && root.idleElapsed >= root.idleTimeout) {
				root.motionEnergy = 0;
				root.hasMouseBaseline = false;
				root.overlayActive = true;  // dimmed (fullyBlack stays false)
			} else if (root.overlayActive && !root.fullyBlack
					&& root.idleElapsed >= root.idleTimeout + root.dimGraceSeconds) {
				root.fullyBlack = true;
			}
		}
	}

	// Fallback when libinput is unreadable: the compositor's own idle signal.
	// Permission-free, but mouse jitter resets it — hence only a fallback.
	// respectInhibitors (default true) means it honours real inhibitors.
	IdleMonitor {
		timeout: root.idleTimeout
		onIsIdleChanged: if (isIdle && root.libinputUnavailable && !root.overlayActive) root.show()
	}

	// Bleed off dismissal-motion so only a sustained deliberate move crosses
	// the threshold, not slow drift.
	Timer {
		interval: root.motionDrainMs
		repeat: true
		running: root.overlayActive
		onTriggered: root.motionEnergy *= root.motionDecay
	}

	// A tinted, everything-covering overlay per monitor. Opacity carries the
	// Off/Dimmed/Black state; the Behavior makes every change a slow fade.
	Variants {
		model: Quickshell.screens

		// qmllint disable uncreatable-type
		PanelWindow {
			required property ShellScreen modelData
			screen: modelData

			// Mapped only while active, so dismissal removes it instantly.
			// The tint still fades in and deepens via the colour animation.
			visible: root.overlayActive
			focusable: root.overlayActive
			color: "transparent"
			WlrLayershell.layer: WlrLayer.Overlay
			WlrLayershell.keyboardFocus: root.overlayActive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
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

			Item {
				anchors.fill: parent
				focus: true
				enabled: root.overlayActive

				Keys.onPressed: () => root.hide()

				MouseArea {
					id: dismissArea
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.BlankCursor  // no pointer over the overlay
					acceptedButtons: Qt.AllButtons

					onPressed: () => root.hide()
					onWheel: () => root.hide()

					// Fresh reference whenever the pointer (re)enters a monitor,
					// so crossing screens isn't read as one huge jump.
					onEntered: root.hasMouseBaseline = false

					onPositionChanged: (mouse) => {
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

						if (root.motionEnergy >= root.motionThreshold * dismissArea.width)
							root.hide();
					}
				}
			}
		}
	}
}