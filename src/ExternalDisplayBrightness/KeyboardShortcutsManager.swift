import AppKit

// Manages the global keyboard shortcuts for the application
// Uses CGEvents, which requires accessibility permissions, but it's the only way to be able to consume global keyboard shortcuts
// Used as a singleton via KeyboardShortcutsManager.shared
class KeyboardShortcutsManager: NSObject {
	static let shared = KeyboardShortcutsManager()
	
	typealias Handler = (() -> Void)
	typealias HandlerWithFlags = ((CGEventFlags) -> Void)
	
	// Represents the action to be taken when a keyboard shortcut is pressed
	class KeyAction {
		var keycode: Int64
		var handler: Any
		
		var key: String {
			get {
				return KeyboardShortcutsManager.keysForKeycode[keycode] ?? ""
			}
			set {
				self.keycode = KeyboardShortcutsManager.keycodesForKey[newValue] ?? -1
			}
		}
		
		init(keycode: Int64, handler: @escaping Handler) {
			self.keycode = keycode
			self.handler = handler
		}
		
		init(keycode: Int64, handler: @escaping HandlerWithFlags) {
			self.keycode = keycode
			self.handler = handler
		}
		
		func remove() {
			KeyboardShortcutsManager.shared.removeAction(self)
		}
	}
	
	var isRegistered: Bool = false
	private var actions: [KeyAction] = []
	
	override private init() {
		super.init()
		registerEventMonitor()
	}
	
	// creates the CGEvent tap to watch for keyboard events
	@discardableResult
	private func registerEventMonitor() -> Bool {
		if !self.isRegistered && AXIsProcessTrusted() {
			let runloop: CFRunLoop = CFRunLoopGetCurrent()
			let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
			if let eventTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: eventMask, callback: self.keyboardCallback, userInfo: nil) {
				let source: CFRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
				
				CFRunLoopAddSource(runloop, source, CFRunLoopMode.commonModes)
				CGEvent.tapEnable(tap: eventTap, enable: true)
				self.isRegistered = true
			}
		}
		return self.isRegistered
	}
	
	// the keyboard event handler
	// filters all keyboard events and processes the ones with handlers registered for them
	private let keyboardCallback: CGEventTapCallBack = { _, eventType, event, _ -> Unmanaged<CGEvent>? in
		if [.keyDown, .keyUp, .flagsChanged].contains(eventType) {
			let keycode = event.getIntegerValueField(CGEventField.keyboardEventKeycode)
			let actions = KeyboardShortcutsManager.shared.actions.filter { action in action.keycode == keycode }
			if !actions.isEmpty {
				if eventType == .keyDown {
					for action in actions {
						DispatchQueue.main.async {
							if action.handler is Handler {
								(action.handler as? Handler)?()
							}
							else if action.handler is HandlerWithFlags {
								(action.handler as? HandlerWithFlags)?(event.flags)
							}
						}
					}
				}
				return nil
			}
		}
		return Unmanaged.passRetained(event)
	}
	
	@discardableResult
	func addHandler(forKey key: String, handler: @escaping Handler) -> KeyAction {
		return self.addHandler(forKeycode: type(of: self).keycodesForKey[key] ?? -1, handler: handler)
	}
	
	@discardableResult
	func addHandler(forKey key: String, handler: @escaping HandlerWithFlags) -> KeyAction {
		return self.addHandler(forKeycode: type(of: self).keycodesForKey[key] ?? -1, handler: handler)
	}
	
	@discardableResult
	func addHandler(forKeycode keycode: Int64, handler: @escaping Handler) -> KeyAction {
		let keyAction = KeyAction(keycode: keycode, handler: handler)
		self.actions.append(keyAction)
		return keyAction
	}
	
	@discardableResult
	func addHandler(forKeycode keycode: Int64, handler: @escaping HandlerWithFlags) -> KeyAction {
		let keyAction = KeyAction(keycode: keycode, handler: handler)
		self.actions.append(keyAction)
		return keyAction
	}
	
	func removeAllHandlers(forKey key: String) {
		self.removeAllHandlers(forKeycode: type(of: self).keycodesForKey[key])
	}
	
	func removeAllHandlers(forKeycode keycode: Int64?) {
		self.actions = self.actions.filter({ value in value.keycode != keycode })
	}
	
	func removeAction(_ action: KeyAction) {
		self.actions = self.actions.filter({ value in value !== action })
	}
	
	// the keycodes for the keys relevant to this application
	private static let keycodesForKey: [String: Int64] = [
		"F1": 122,
		"F2": 120,
		"F3": 99,
		"F4": 118,
		"F5": 96,
		"F6": 97,
		"F7": 98,
		"F8": 100,
		"F9": 101,
		"F10": 109,
		"F11": 103,
		"F12": 111,
		"F13": 105,
		"F14": 107,
		"F15": 113,
		"F16": 106,
		"F17": 64,
		"F18": 79,
		"F19": 80,
		"F20": 90,
	]
	
	// reversed keycodesForKey
	private static let keysForKeycode: [Int64: String] = [Int64: String](uniqueKeysWithValues: keycodesForKey.map({ ($1, $0) }))
}
