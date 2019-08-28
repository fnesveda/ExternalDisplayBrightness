import AppKit

// Controls the preferences window
class PreferencesWindowController: NSWindowController, NSWindowDelegate {
	@IBOutlet private weak var decreaseBrightnessKey: NSPopUpButton?
	@IBOutlet private weak var increaseBrightnessKey: NSPopUpButton?
	
	// needed to access the singleton from Interface Builder
	@objc dynamic weak var sharedLoginItemManager = LoginItemManager.shared
	
	@objc dynamic var showCaution: Bool = false
	@objc dynamic var isPrivileged: Bool {
		return AXIsProcessTrusted()
	}
	
	override var windowNibName: NSNib.Name? {
		return "PreferencesWindow"
	}
	
	override func windowDidLoad() {
		super.windowDidLoad()
		self.window?.center()
		self.updateShowCaution()
	}
	
	override func showWindow(_ sender: Any?) {
		if !(self.window?.isVisible ?? true) {
			self.window?.center()
		}
		super.showWindow(sender)
		UserDefaults.standard.set(false, forKey: "showPreferencesOnNextLaunch")
	}
	
	func windowWillClose(_: Notification) {
		(NSApplication.shared.delegate as? AppDelegate)?.deactivateApp()
	}
	
	func windowDidUpdate(_: Notification) {
		LoginItemManager.shared.updateEnabled()
	}
	
	@IBAction private func updateShowCaution(_: Any? = nil) {
		self.showCaution = self.decreaseBrightnessKey?.titleOfSelectedItem == self.increaseBrightnessKey?.titleOfSelectedItem
	}
}
