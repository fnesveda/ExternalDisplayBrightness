import AppKit

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
	var preferencesWindowController: PreferencesWindowController?
	
	func applicationWillFinishLaunching(_ notification: Notification) {
		// don't put the "Enter Full Screen" menu item into the View submenu, there are no windows to put to fullscreen
		UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
	}
	
	func applicationDidFinishLaunching(_: Notification) {
		UserDefaults.standard.register(defaults: [
			"decreaseBrightnessKey": "F14",
			"increaseBrightnessKey": "F15",
			"changeBrightnessOnAllDisplaysAtOnce": 1,
			"changeBrightnessOnAllDisplaysAtOnceRequiresCommand": 1,
			"showPreferencesOnNextLaunch": true,
		])
		
		// get the Accessibility privileges status
		let (privileged, willEnable) = acquirePrivileges()
		
		if privileged {
			// force BrightnessManager to load
			_ = BrightnessManager.shared
		}
		else if !willEnable {
			NSApplication.shared.terminate(self)
		}
		
		self.preferencesWindowController = PreferencesWindowController()
		
		// open the preferences window on first launch, on launch which is not from a login item, or when the user didn't grant Accessibility privileges
		let event = NSAppleEventManager.shared().currentAppleEvent
		if (!(event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem))
			|| UserDefaults.standard.bool(forKey: "showPreferencesOnNextLaunch") || !privileged
		{
			self.activateApp(ignoringOtherApps: privileged)
			// display the preferences window after a short delay, otherwise there is a chance we will not own the menubar
			DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { self.showPreferencesWindow(self) }
		}
	}
	
	// show the preferences window when the user tries to launch the app and it's already running
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		self.activateApp(ignoringOtherApps: true)
		// display the preferences window after a short delay, otherwise there is a chance we will not own the menubar
		DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { self.showPreferencesWindow(sender) }
		
		return false
	}
	
	@IBAction private func showPreferencesWindow(_ sender: Any?) {
		self.preferencesWindowController?.showWindow(sender)
	}
	
	@IBAction private func showAboutPanel(_ sender: Any?) {
		let link = "https://www.nesveda.com/projects/ExternalDisplayBrightness"
		let credits = NSAttributedString(string: link, attributes: [.link: NSURL(string: link) ?? ""])
		NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
	}
	
	// relaunch app pretending the user opened it themselves, so it doesn't inherit the permissions of the current instance of the app
	@IBAction private func relaunchApp(_ sender: Any?) {
		let shellPath = "/bin/sh"
		let shellArgs = ["-c", "sleep 1; /usr/bin/open " + Bundle.main.bundlePath]
		
		if (try? Process.run(URL(fileURLWithPath: shellPath), arguments: shellArgs)) != nil {
			NSApplication.shared.terminate(self)
		}
	}
	
	// show the main menu and Dock icon
	func activateApp(ignoringOtherApps force: Bool = false) {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: force)
	}
	
	// hide the main menu and Dock icon
	func deactivateApp() {
		DispatchQueue.main.async { NSApplication.shared.setActivationPolicy(.accessory) }
	}
	
	// try to get Accessibility privileges, asking the user for them nicely if they're not granted
	@discardableResult
	private func acquirePrivileges() -> (privileged: Bool, willUserEnablePrivileges: Bool) {
		let accessEnabled = AXIsProcessTrusted()
		var willEnable = false
		if !accessEnabled {
			self.activateApp(ignoringOtherApps: true)
			let alert = NSAlert()
			alert.messageText = NSLocalizedString("AXProcessUntrustedAlertMessageText", comment: "Message text for the alert about missing accessibility permissions")
			alert.informativeText = NSLocalizedString("AXProcessUntrustedAlertInformativeText", comment: "Informative text for the alert about missing accessibility permissions")
			alert.alertStyle = .warning
			alert.addButton(withTitle: NSLocalizedString("AXProcessUntrustedAlertConfirmButton", comment: "Confirmation button title for the alert about missing accessibility permissions"))
			alert.addButton(withTitle: NSLocalizedString("AXProcessUntrustedAlertCancelButton", comment: "Cancel button title for the alert about missing accessibility permissions"))
			
			let result = alert.runModal()
			if result == .alertFirstButtonReturn {
				willEnable = true
				AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
				
				let runningApps = NSWorkspace.shared.runningApplications
				let authApp = runningApps.filter({ app in app.bundleIdentifier == "com.apple.accessibility.universalAccessAuthWarn" }).first
				authApp?.activate(options: .activateIgnoringOtherApps)
			}
		}
		
		return (accessEnabled, willEnable)
	}
}
