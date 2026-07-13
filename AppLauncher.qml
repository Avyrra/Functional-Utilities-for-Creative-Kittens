import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

Scope {
	id: root

	// Colors
	property color colorPanel:     Qt.rgba(0, 0, 0, 1)
	property color colorSelection: Qt.rgba(0.7, 0.15, 0.2, 0.7)
	property color colorHover:    Qt.rgba(1, 1, 1, 0.2)
	property color colorText:         "#c3c1c1"
	property color colorTextMuted:    Qt.rgba(1, 1, 1, 0.4)

	// Layout
	property int    launcherWidth:      400
	property real   positionX: 0.5		// 0-1, resolution-independent horizontal position
	property real   positionY: 0.17	// 0-1, resolution-independent vertical position
	property string anchor:    "top-center"	// top-left, top-center, top-right, center-left, center, center-right, bottom-left, bottom-center, bottom-right

	readonly property real anchorX: anchor.includes("left") ? 0 : anchor.includes("right") ? 1 : 0.5
	readonly property real anchorY: anchor.startsWith("top") ? 0 : anchor.startsWith("bottom") ? 1 : 0.5
	property int    searchBarHeight:    44
	property int    searchBarRadius:    12
	property int    searchPadding:      18		// left/right padding inside the search bar
	property int    listRadius:         12
	property int    listPadding:        6
	property int    listSpacing:        8		// gap between search bar and list
	property int    itemHeight:         34
	property int    itemRadius:         7
	property int    itemTextLeftMargin: 8
	property int    maxVisibleResults:       16
	property int    modeIconLeftMargin: 14
	property int    modeIconSlide:      16		// how far input slides right to reveal mode icon
	property int    resizeHandleHeight: 16
	property string itemFont:           "Sofia Sans"
	property int    itemTextSize:       16

	// Animations (ms)
	property int listResizeDuration:   150
	property int fadeDuration:         150
	property int selectorLeadDuration: 40
	property int selectorTrailDuration:     40
	property int selectorTrailPerItem:  25
	property int selectorTrailMax:      200
	property int autocompleteDelay:    80		// pause after autocomplete accepts before launching
	property int modeIconDuration:     150

	// Search and browser
	property string searchEngineUrl:  "https://www.google.com/search?q="
	property int    urlMaxResults:    5
	property int    searchMaxResults: 3
	property var    pinnedUrls: [
		"google.com",
		"youtube.com",
		"github.com",
		"reddit.com",
		"archlinux.org",
		"wiki.archlinux.org",
		"aur.archlinux.org",
		"archlinux.org/packages",
	]

	// Frecency
	property int frecencyHalfLifeDays: 30
	property int searchHalfLifeDays:   10
	property int frecencyMaxLaunches:  50

	// Internal state
	property var  launchHistory:         ({})
	property var  urlHistory:            ({})
	property var  searchHistory:         ({})
	property int  selectedIndex:         0
	property int  firstVisibleIndex:     0
	property int  previousVisualIndex:   0
	property bool skipNextAnimation:     false
	property real listHeight:    0
	property real launcherOpacity:       0
	property bool isOpening:     false
	property bool isOpen:                false
	property string typedQuery:        ""
	property bool isNavigating:          false
	property bool showFrequentApps:      false
	property int  temporaryMaxResults: -1
	property bool isListAbove: root.positionY > 0.5	// true when bar is in the lower half; list renders above

	// Derived state
	property string searchMode: {
		const q = root.typedQuery.trim();
		if (q === "") return "neutral";
		const values = filteredApps.values;
		if (values.length > 0) {
			const sel = values[Math.min(root.selectedIndex, values.length - 1)];
			if (sel?.isUrl) return "url";
			if (sel?.isSearch) return "search";
		}
		if (q.startsWith("http://") || q.startsWith("https://")) return "url";
		if (!q.includes(" ") && q.includes(".")) return "url";
		return values.length === 0 ? "search" : "neutral";
	}

	property string autocompleteSuggestion: {
		const q = searchInput.text;
		if (q !== root.typedQuery || q.trim() === "" || root.listHeight < 0.5) return "";
		const values = filteredApps.values;
		if (values.length === 0) return "";
		const top = values[0];
		const candidate = top.isUrl ? top.url : top.isSearch ? top.query : (top.name ?? "");
		return candidate.toLowerCase().startsWith(q.toLowerCase()) && candidate.length > q.length ? candidate : "";
	}

	// Animations
	NumberAnimation {
		id: listHeightAnim
		target: root; property: "listHeight"
		easing.type: Easing.OutCubic; duration: root.listResizeDuration
	}

	NumberAnimation {
		id: opacityAnim
		target: root; property: "launcherOpacity"
		easing.type: Easing.OutCubic; duration: root.fadeDuration
		onStopped: if (!root.isOpen) launcherPanel.visible = false
	}

	Timer {
		id: autocompleteTimer
		interval: root.autocompleteDelay; repeat: false
		onTriggered: {
			const q = root.typedQuery.trim();
			if (filteredApps.values.length > 0 && root.listHeight > 0.5) {
				const entry = filteredApps.values[root.selectedIndex];
				if (entry.isUrl || entry.isSearch) {
					root.openInBrowser(entry.isUrl ? entry.url : entry.query);
					root.closeLauncher();
				} else if (entry) {
					root.launchApp(entry);
				}
			} else if (q !== "") {
				root.openInBrowser(q);
				root.closeLauncher();
			}
		}
	}

	// History persistence
	FileView {
		id: historyFile
		path: Quickshell.env("HOME") + "/.config/quickshell/app-launcher.json"
		blockLoading: true
	}

	Component.onCompleted: {
		try {
			const text = historyFile.text();
			if (!text) return;
			const data = JSON.parse(text);
			if (data.apps !== undefined) {
				root.launchHistory = data.apps;
				const rawUrls = data.urls ?? {};
				root.urlHistory = Array.isArray(rawUrls)
					? Object.fromEntries(rawUrls.map(u => [u, [Date.now()]]))
					: rawUrls;
				root.searchHistory = data.searches    ?? {};
				root.showFrequentApps  = data.showFrequentApps ?? false;
				root.maxVisibleResults  = data.maxVisibleResults ?? 16;
			} else {
				root.launchHistory = data;
			}
		} catch(e) {}
	}

	function saveHistory() {
		historyFile.setText(JSON.stringify({
			apps: root.launchHistory, urls: root.urlHistory, searches: root.searchHistory,
			showFrequentApps: root.showFrequentApps, maxVisibleResults: root.maxVisibleResults
		}));
	}

	onShowFrequentAppsChanged: root.saveHistory()
	onMaxVisibleResultsChanged: root.saveHistory()

	// Frecency scoring
	function calculateFrecency(launches, halfLifeMs) {
		if (!launches?.length) return 0;
		const now = Date.now();
		return launches.reduce((s, ts) => s + Math.exp(-((now - ts) / halfLifeMs) * Math.LN2), 0);
	}

	function frecencyScore(appId)   { return calculateFrecency(root.launchHistory[appId], root.frecencyHalfLifeDays * 86400000); }
	function urlFrecencyScore(url)  { return calculateFrecency(root.urlHistory[url],       root.frecencyHalfLifeDays * 86400000); }
	function searchFrecencyScore(q) { return calculateFrecency(root.searchHistory[q],      root.searchHalfLifeDays   * 86400000); }

	// History recording
	function recordEntry(dict, key) {
		const updated = Object.assign({}, dict);
		if (!updated[key]) updated[key] = [];
		updated[key].push(Date.now());
		if (updated[key].length > root.frecencyMaxLaunches)
			updated[key] = updated[key].slice(-root.frecencyMaxLaunches);
		return updated;
	}

	function recordLaunch(appId) { root.launchHistory = recordEntry(root.launchHistory, appId);                              root.saveHistory(); }
	function recordUrl(url)      { root.urlHistory     = recordEntry(root.urlHistory,    url.replace(/^https?:\/\//, "")); root.saveHistory(); }
	function recordSearch(query) { root.searchHistory  = recordEntry(root.searchHistory, query);                             root.saveHistory(); }

	// History removal
	function removeEntry(dict, key) { const d = Object.assign({}, dict); delete d[key]; return d; }
	function removeUrl(url)  { root.urlHistory    = removeEntry(root.urlHistory,    url);  root.saveHistory(); }
	function removeSearch(q) { root.searchHistory = removeEntry(root.searchHistory, q);    root.saveHistory(); }

	// Fuzzy matching
	function fuzzyMatch(str, q) {
		let si = 0;
		for (let qi = 0; qi < q.length; qi++) {
			while (si < str.length && str[si] !== q[qi]) si++;
			if (si >= str.length) return false;
			si++;
		}
		return true;
	}

	// List height
	function animateListHeight(target) { listHeightAnim.stop(); listHeightAnim.to = target; listHeightAnim.start(); }

	function targetListHeight() {
		if (root.typedQuery.trim() === "" && !root.showFrequentApps) return 0;
		if (resultsList.count === 0) return 0;
		const count = root.temporaryMaxResults > 0
			? root.temporaryMaxResults
			: Math.min(resultsList.count, root.maxVisibleResults);
		return count * root.itemHeight + root.listPadding * 2;
	}

	// Autocomplete
	function acceptAutocomplete() {
		if (root.autocompleteSuggestion === "") return;
		searchInput.text = root.autocompleteSuggestion;
		searchInput.cursorPosition = searchInput.text.length;
	}

	// Navigation
	function itemDisplayText(entry) {
		if (!entry) return root.typedQuery;
		return entry.isUrl ? entry.url : entry.isSearch ? entry.query : (entry.name ?? "");
	}

	function navigateTo(index) {
		root.isNavigating = true;
		root.selectedIndex = index;
		const text = root.itemDisplayText(filteredApps.values[index]);
		searchInput.text = text;
		searchInput.cursorPosition = text.length;
		root.isNavigating = false;
	}

	function restoreQuery() {
		root.isNavigating = true;
		searchInput.text = root.typedQuery;
		searchInput.cursorPosition = root.typedQuery.length;
		root.isNavigating = false;
	}

	// Launch and browser
	function openInBrowser(text) {
		let url, isUrl = false;
		if (text.startsWith("http://") || text.startsWith("https://")) {
			url = text; isUrl = true;
		} else if (!text.includes(" ") && text.includes(".")) {
			url = "https://" + text; isUrl = true;
		} else {
			url = root.searchEngineUrl + encodeURIComponent(text);
			root.recordSearch(text);
		}
		if (isUrl) root.recordUrl(url);
		Quickshell.execDetached(["sh", "-c",
			'b=$(xdg-settings get default-web-browser 2>/dev/null); ' +
			'e=$(grep -rh "^Exec=" /usr/share/applications/"$b" ~/.local/share/applications/"$b" 2>/dev/null | head -1 | sed "s/^Exec=//;s/ .*//"); ' +
			'[ -n "$e" ] && exec "$e" --new-window "$1" || xdg-open "$1"',
			"--", url
		]);
	}

	function closeLauncher() {
		root.isOpen = false;
		root.temporaryMaxResults = -1;
		root.animateListHeight(0);
		opacityAnim.stop();
		opacityAnim.to = 0;
		opacityAnim.start();
	}

	function launchApp(entry) {
	    root.recordLaunch(entry.id ?? "");
	    Quickshell.execDetached(["gtk-launch", entry.id]);
	    root.closeLauncher();
	}

	// IPC
	IpcHandler {
		target: "app-launcher"
		function toggle(): void {
			if (!root.isOpen) {
				root.isOpen = true;
				root.isOpening = true;
				root.listHeight = 0;
				root.launcherOpacity = 0;
				root.typedQuery = "";
				root.temporaryMaxResults = -1;
				root.skipNextAnimation = true;
				root.firstVisibleIndex = 0;
				root.selectedIndex = 0;
				launcherPanel.visible = true;
				searchInput.text = "";
				searchInput.forceActiveFocus();
				opacityAnim.stop();
				opacityAnim.to = 1;
				opacityAnim.start();
				Qt.callLater(function() {
					root.isOpening = false;
					root.skipNextAnimation = false;
					root.animateListHeight(root.targetListHeight());
				});
			} else {
				root.closeLauncher();
			}
		}
	}

	// App and history filtering
	ScriptModel {
		id: filteredApps
		objectProp: "id"
		values: {
			const all = [...DesktopEntries.applications.values];
			const q = root.typedQuery.toLowerCase();
			if (q.trim() === "") {
				return all.sort((a, b) => {
					const diff = root.frecencyScore(b.id ?? "") - root.frecencyScore(a.id ?? "");
					return diff !== 0 ? diff : a.name.localeCompare(b.name);
				});
			}

			const apps = all
				.filter(d => root.fuzzyMatch((d.name ?? "").toLowerCase(), q))
				.sort((a, b) => {
					const aS = a.name.toLowerCase().startsWith(q);
					const bS = b.name.toLowerCase().startsWith(q);
					return aS !== bS ? (aS ? -1 : 1) : a.name.localeCompare(b.name);
				});

			const pinnedSet = new Set(root.pinnedUrls);
			const allUrlKeys = [...new Set([...Object.keys(root.urlHistory), ...root.pinnedUrls])];
			const urls = allUrlKeys
				.filter(u => root.fuzzyMatch(u.toLowerCase(), q))
				.sort((a, b) => root.urlFrecencyScore(b) - root.urlFrecencyScore(a))
				.slice(0, root.urlMaxResults)
				.map(u => ({ id: "__url__" + u, name: "󰖟   " + u, isUrl: true, isPinned: pinnedSet.has(u), url: u }));

			const searches = Object.keys(root.searchHistory)
				.filter(s => root.fuzzyMatch(s.toLowerCase(), q))
				.sort((a, b) => root.searchFrecencyScore(b) - root.searchFrecencyScore(a))
				.slice(0, root.searchMaxResults)
				.map(s => ({ id: "__search__" + s, name: "󰍉   " + s, isSearch: true, query: s }));

			const combined = [...apps, ...urls, ...searches];

			const acIdx = combined.findIndex(item => {
				const c = item.isUrl ? item.url : item.isSearch ? item.query : (item.name ?? "");
				return c.toLowerCase().startsWith(q);
			});
			if (acIdx > 0) combined.unshift(combined.splice(acIdx, 1)[0]);

			return combined;
		}

		onValuesChanged: {
			root.firstVisibleIndex = 0;
			root.skipNextAnimation = true;
			root.selectedIndex = 0;
			root.restoreQuery();
			if (launcherPanel.visible && !root.isOpening) {
				Qt.callLater(function() {
					root.skipNextAnimation = false;
					root.animateListHeight(root.targetListHeight());
				});
			}
		}
	}

	// UI
	// qmllint disable uncreatable-type
	PanelWindow {
		id: launcherPanel
		visible: false; focusable: true; color: "transparent"
		WlrLayershell.layer: WlrLayer.Overlay
		WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
		WlrLayershell.namespace: "quickshell-launcher"
		exclusionMode: ExclusionMode.Ignore
		anchors { top: true; bottom: true; left: true; right: true }

		Item {
			anchors.fill: parent
			opacity: root.launcherOpacity

			MouseArea { anchors.fill: parent; onClicked: root.closeLauncher() }

			// Search bar
			Rectangle {
				id: searchBar
				x: parent.width  * root.positionX - root.launcherWidth   * root.anchorX
				y: parent.height * root.positionY - root.searchBarHeight * root.anchorY
				width: root.launcherWidth; height: root.searchBarHeight
				radius: root.searchBarRadius; color: root.colorPanel

				TextMetrics { id: inputMetrics; font: searchInput.font; text: searchInput.text }

				// Mode icon
				Text {
					anchors.left: parent.left; anchors.leftMargin: root.modeIconLeftMargin
					anchors.verticalCenter: parent.verticalCenter
					font.pixelSize: root.itemTextSize; font.family: root.itemFont
					color: root.colorTextMuted
					text: root.searchMode === "url" ? "󰖟" : "󰍉"
					opacity: root.searchMode !== "neutral" ? 1 : 0
					visible: opacity > 0.01
					Behavior on opacity { NumberAnimation { duration: root.modeIconDuration; easing.type: Easing.OutCubic } }
				}

				// Input container
				Item {
					anchors { top: parent.top; bottom: parent.bottom; right: parent.right; rightMargin: root.searchPadding; left: parent.left }
					anchors.leftMargin: root.searchMode !== "neutral"
						? root.searchPadding + root.modeIconSlide
						: root.searchPadding
					Behavior on anchors.leftMargin { NumberAnimation { duration: root.modeIconDuration; easing.type: Easing.OutCubic } }

					// Autocomplete ghost text
					Text {
						anchors { left: parent.left; leftMargin: inputMetrics.advanceWidth; top: parent.top; bottom: parent.bottom; right: parent.right }
						verticalAlignment: Text.AlignVCenter
						color: root.colorTextMuted; font: searchInput.font; clip: true
						text: root.autocompleteSuggestion !== "" ? root.autocompleteSuggestion.slice(searchInput.text.length) : ""
						visible: text !== ""
					}

					TextInput {
						id: searchInput
						anchors.fill: parent
						color: root.colorText
						font.pixelSize: root.itemTextSize; font.family: root.itemFont
						clip: true; focus: true
						verticalAlignment: TextInput.AlignVCenter

						Text {
							anchors.fill: parent
							text: "Search"; color: root.colorTextMuted; font: parent.font
							visible: !parent.text; verticalAlignment: Text.AlignVCenter
						}

						Keys.onEscapePressed: root.closeLauncher()

						onTextChanged: {
							if (root.isNavigating) return;
							root.typedQuery = text;
							root.temporaryMaxResults = -1;
							if (text === "") {
								root.animateListHeight(root.targetListHeight());
							}
						}

						Keys.onPressed: event => {
							const listOpen = root.listHeight > 0.5 && resultsList.count > 0;
							if (event.key === Qt.Key_Down) {
								event.accepted = true;
								if (listOpen) {
									if (root.isListAbove) root.navigateTo(Math.max(root.selectedIndex - 1, 0));
									else root.navigateTo(Math.min(root.selectedIndex + 1, resultsList.count - 1));
								}
							} else if (event.key === Qt.Key_Up) {
								event.accepted = true;
								if (listOpen) {
									if (root.isListAbove) {
										if (root.selectedIndex < resultsList.count - 1) root.navigateTo(root.selectedIndex + 1);
										else root.restoreQuery();
									} else {
										if (root.selectedIndex > 0) root.navigateTo(root.selectedIndex - 1);
										else root.restoreQuery();
									}
								}
							} else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
								event.accepted = true;
								const q = root.typedQuery.trim();
								if (root.autocompleteSuggestion !== "") {
									root.acceptAutocomplete();
									autocompleteTimer.start();
								} else if (listOpen) {
									const entry = filteredApps.values[root.selectedIndex];
									if (entry.isUrl || entry.isSearch) {
										root.openInBrowser(entry.isUrl ? entry.url : entry.query);
										root.closeLauncher();
									} else {
										root.launchApp(entry);
									}
								} else if (q !== "") {
									root.openInBrowser(q);
									root.closeLauncher();
								}
							} else if (event.key === Qt.Key_Tab) {
								event.accepted = true;
								if (root.autocompleteSuggestion !== "") {
									root.acceptAutocomplete();
								} else if (root.typedQuery.trim() === "") {
									root.showFrequentApps = !root.showFrequentApps;
									root.animateListHeight(root.targetListHeight());
								}
							} else if (event.key === Qt.Key_Right) {
								if (searchInput.cursorPosition === searchInput.text.length && root.autocompleteSuggestion !== "") {
									event.accepted = true;
									root.acceptAutocomplete();
								}
							}
						}
					}
				}
			}

			// Results list
			Rectangle {
				id: listBox
				x: searchBar.x
				y: root.isListAbove
					? searchBar.y - root.listSpacing - root.listHeight
					: searchBar.y + root.searchBarHeight + root.listSpacing
				width: root.launcherWidth; height: root.listHeight
				radius: root.listRadius; color: root.colorPanel
				visible: root.listHeight > 0.5; clip: true

				// Selection highlight
				Rectangle {
					id: highlight
					x: root.listPadding; width: parent.width - root.listPadding * 2
					radius: root.itemRadius; color: root.colorSelection; z: 0
					// topEdge/bottomEdge = distance from the near edge (top in normal, bottom in isListAbove)
					property real topEdge:    root.listPadding
					property real bottomEdge: root.listPadding + root.itemHeight
					y: root.isListAbove ? parent.height - bottomEdge : topEdge
					height: bottomEdge - topEdge

					NumberAnimation { id: topAnim;    target: highlight; property: "topEdge";    easing.type: Easing.OutCubic }
					NumberAnimation { id: bottomAnim; target: highlight; property: "bottomEdge"; easing.type: Easing.OutCubic }

					Connections {
						target: root
						function onSelectedIndexChanged() {
							const vis = Math.min(resultsList.count, root.maxVisibleResults);
							let newFirst = root.firstVisibleIndex;
							if (root.selectedIndex >= newFirst + vis) newFirst = root.selectedIndex - vis + 1;
							else if (root.selectedIndex < newFirst)  newFirst = root.selectedIndex;

							const vi  = root.selectedIndex - newFirst;
							// Distance from the near edge (top in normal mode, bottom in isListAbove)
							const top = root.listPadding + vi * root.itemHeight;
							const bot = top + root.itemHeight;

							topAnim.stop(); bottomAnim.stop();

							if (root.skipNextAnimation) {
								root.skipNextAnimation = false;
								highlight.topEdge = top; highlight.bottomEdge = bot;
								root.firstVisibleIndex = newFirst;
								resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
								root.previousVisualIndex = vi;
								return;
							}

							const dist = Math.abs(vi - root.previousVisualIndex);
							const slow = Math.min(root.selectorTrailDuration + dist * root.selectorTrailPerItem, root.selectorTrailMax);
							const down = root.isListAbove ? vi <= root.previousVisualIndex : vi >= root.previousVisualIndex;
							if (root.isListAbove) {
								topAnim.duration    = down ? root.selectorLeadDuration : slow;
								bottomAnim.duration = down ? slow : root.selectorLeadDuration;
							} else {
								bottomAnim.duration = down ? root.selectorLeadDuration : slow;
								topAnim.duration    = down ? slow : root.selectorLeadDuration;
							}
							topAnim.to = top; bottomAnim.to = bot;
							topAnim.start(); bottomAnim.start();

							root.firstVisibleIndex = newFirst;
							resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
							root.previousVisualIndex = vi;
						}
					}
				}

				// Result items
				ListView {
					id: resultsList
					anchors.fill: parent; anchors.margins: root.listPadding
					model: filteredApps; spacing: 0; clip: true
					boundsBehavior: Flickable.StopAtBounds; interactive: false; z: 1
					verticalLayoutDirection: root.isListAbove ? ListView.BottomToTop : ListView.TopToBottom

					delegate: Rectangle {
						id: delegateRoot
						required property var modelData
						required property int index
						width: resultsList.width; height: root.itemHeight; color: "transparent"

						Rectangle {
							anchors.fill: parent; radius: root.itemRadius; color: root.colorHover
							visible: hoverArea.containsMouse && delegateRoot.index !== root.selectedIndex
						}

						Text {
							anchors.verticalCenter: parent.verticalCenter
							anchors.left: parent.left; anchors.leftMargin: root.itemTextLeftMargin
							anchors.right: parent.right
							anchors.rightMargin: (delegateRoot.modelData.isUrl || delegateRoot.modelData.isSearch) ? 32 : root.itemTextLeftMargin
							text: delegateRoot.modelData.name ?? ""; color: root.colorText
							font.pixelSize: root.itemTextSize; font.family: root.itemFont
							elide: Text.ElideRight
						}

						// Delete button
						Item {
							visible: !!(delegateRoot.modelData.isUrl || delegateRoot.modelData.isSearch) && !delegateRoot.modelData.isPinned
							anchors.right: parent.right; anchors.rightMargin: 6
							anchors.verticalCenter: parent.verticalCenter
							width: 28; height: 28; z: 2

							Text {
								anchors.centerIn: parent
								text: (xArea.pressed && xArea.containsMouse) ? "󰛌" : "󰆴"
								font.pixelSize: 18
								color: xArea.containsMouse ? root.colorText : root.colorTextMuted
							}

							MouseArea {
								id: xArea; anchors.fill: parent; hoverEnabled: true
								onReleased: {
									if (!containsMouse) return;
									if (delegateRoot.modelData.isUrl) root.removeUrl(delegateRoot.modelData.url);
									else root.removeSearch(delegateRoot.modelData.query);
								}
							}
						}

						MouseArea {
							id: hoverArea; anchors.fill: parent; hoverEnabled: true
							onClicked: {
								if (delegateRoot.index !== root.selectedIndex) {
									root.selectedIndex = delegateRoot.index;
								} else if (delegateRoot.modelData.isUrl || delegateRoot.modelData.isSearch) {
									root.openInBrowser(delegateRoot.modelData.isUrl ? delegateRoot.modelData.url : delegateRoot.modelData.query);
									root.closeLauncher();
								} else {
									root.launchApp(delegateRoot.modelData);
								}
							}
						}
					}
				}

				// Resize handle
				MouseArea {
					visible: root.listHeight > 0.5
					anchors.top:    root.isListAbove ? parent.top    : undefined
					anchors.bottom: root.isListAbove ? undefined      : parent.bottom
					anchors.left: parent.left; anchors.right: parent.right
					height: root.resizeHandleHeight; hoverEnabled: true; cursorShape: Qt.SizeVerCursor; z: 3
					property real dragStartSceneY: 0
					property real dragStartHeight: 0
					onPressed: mouse => {
						dragStartSceneY = mapToItem(null, mouse.x, mouse.y).y;
						dragStartHeight = root.listHeight;
						listHeightAnim.stop();
					}
					onPositionChanged: mouse => {
						if (!pressed) return;
						const dy = mapToItem(null, mouse.x, mouse.y).y - dragStartSceneY;
						const delta = root.isListAbove ? -dy : dy;
						root.listHeight = Math.max(root.itemHeight + root.listPadding * 2, dragStartHeight + delta);
					}
					onReleased: {
						const count = Math.max(1, Math.round((root.listHeight - root.listPadding * 2) / root.itemHeight));
						if (root.showFrequentApps) root.maxVisibleResults = count;
						else root.temporaryMaxResults = count;
						root.animateListHeight(count * root.itemHeight + root.listPadding * 2);
					}
				}
			}
		}
	}
}