import AppKit

// Manages the brightness manipulation of both internal and external displays
// Used as a singleton via BrightnessManager.shared
internal class BrightnessManager: NSObject {
	// A generic display, should not be used directly, but only subclassed
	// This should really be a protocol, but Swift currently doesn't support declaring protocols inside classes
	internal class Display {
		// the display ID
		internal var displayID: CGDirectDisplayID
		// the queue for dispatching display operations, so they're not performed directly and concurrently
		internal var displayQueue: DispatchQueue
		
		init(fromDisplay displayID: CGDirectDisplayID) {
			self.displayID = displayID
			self.displayQueue = DispatchQueue(label: "ExternalDisplayBrightness-\(String(displayID))-\(UUID().uuidString)")
		}
		
		func increaseBrightness(inQuarterSteps useQuarterSteps: Bool = false) {
			self.stepBrightness(.up, inQuarterSteps: useQuarterSteps)
		}
		
		func decreaseBrightness(inQuarterSteps useQuarterSteps: Bool = false) {
			self.stepBrightness(.down, inQuarterSteps: useQuarterSteps)
		}
		
		enum StepDirection: Float { case up = 1; case down = -1 }
		func stepBrightness(_ direction: StepDirection, inQuarterSteps useQuarterSteps: Bool = false) {}
		func changeBrightness(by delta: Float) {}
		func setBrightness(to: Float) {}
		func getBrightness() -> Float { return 0 }
	}
	
	// An internal display, the brightness of which can be manipulated with CoreDisplay
	internal class InternalDisplay: Display {
		// step the brightness up or down, round to the nearest sixteenth or sixty-fourth
		override func stepBrightness(_ direction: StepDirection, inQuarterSteps useQuarterSteps: Bool = false) {
			var step: Float = direction.rawValue / 16.0
			let delta = step / 4
			if useQuarterSteps {
				step = delta
			}
			
			let newBrightness = min(max(0, ceil((self.getBrightness() + delta) / step) * step), 1)
			self.setBrightness(to: newBrightness)
		}
		
		override func changeBrightness(by delta: Float) {
			let currentBrightness = self.getBrightness()
			let newBrightness = min(max(0, currentBrightness + delta), 1)
			return self.setBrightness(to: newBrightness)
		}
		
		override func setBrightness(to brightness: Float) {
			self.displayQueue.sync {
				type(of: self).CoreDisplaySetUserBrightness?(self.displayID, Double(brightness))
				type(of: self).DisplayServicesBrightnessChanged?(self.displayID, Double(brightness))
				BrightnessManager.showBrightnessHUD?(self.displayID, Int(brightness * 64), 64)
			}
		}
		
		override func getBrightness() -> Float {
			return Float(type(of: self).CoreDisplayGetUserBrightness?(self.displayID) ?? 0.5)
		}
		
		// notifies the system that the brightness of a specified display has changed (to update System Preferences etc.)
		// unfortunately Apple doesn't provide a public API for this, so we have to manually extract the function from the DisplayServices framework
		private static var DisplayServicesBrightnessChanged: ((CGDirectDisplayID, Double) -> Void)? {
			let displayServicesPath = CFURLCreateWithString(kCFAllocatorDefault, "/System/Library/PrivateFrameworks/DisplayServices.framework" as CFString, nil)
			if let displayServicesBundle = CFBundleCreate(kCFAllocatorDefault, displayServicesPath) {
				if let funcPointer = CFBundleGetFunctionPointerForName(displayServicesBundle, "DisplayServicesBrightnessChanged" as CFString) {
					typealias DSBCFunctionType = @convention(c) (UInt32, Double) -> Void
					return unsafeBitCast(funcPointer, to: DSBCFunctionType.self)
				}
			}
			return nil
		}
		
		// reads the brightness of a display through the CoreDisplay framework
		// unfortunately Apple doesn't provide a public API for this, so we have to manually extract the function from the CoreDisplay framework
		private static var CoreDisplayGetUserBrightness: ((CGDirectDisplayID) -> Double)? {
			let coreDisplayPath = CFURLCreateWithString(kCFAllocatorDefault, "/System/Library/Frameworks/CoreDisplay.framework" as CFString, nil)
			if let coreDisplayBundle = CFBundleCreate(kCFAllocatorDefault, coreDisplayPath) {
				if let funcPointer = CFBundleGetFunctionPointerForName(coreDisplayBundle, "CoreDisplay_Display_GetUserBrightness" as CFString) {
					typealias CDGUBFunctionType = @convention(c) (UInt32) -> Double
					return unsafeBitCast(funcPointer, to: CDGUBFunctionType.self)
				}
			}
			return nil
		}
		
		// sets the brightness of a display through the CoreDisplay framework
		// unfortunately Apple doesn't provide a public API for this, so we have to manually extract the function from the CoreDisplay framework
		private static var CoreDisplaySetUserBrightness: ((CGDirectDisplayID, Double) -> Void)? {
			let coreDisplayPath = CFURLCreateWithString(kCFAllocatorDefault, "/System/Library/Frameworks/CoreDisplay.framework" as CFString, nil)
			if let coreDisplayBundle = CFBundleCreate(kCFAllocatorDefault, coreDisplayPath) {
				if let funcPointer = CFBundleGetFunctionPointerForName(coreDisplayBundle, "CoreDisplay_Display_SetUserBrightness" as CFString) {
					typealias CDSUBFunctionType = @convention(c) (UInt32, Double) -> Void
					return unsafeBitCast(funcPointer, to: CDSUBFunctionType.self)
				}
			}
			return nil
		}
	}
	
	// An external display, the brightness of which can be manipulated using DDC-CI
	internal class ExternalDisplay: Display {
		// current brightness on a scale of 0 to 1
		private var brightness: Float
		// max brightness value as reported by the display
		private var brightnessScale: Float
		// time when we last set or checked the brightness
		private var lastSetOn: Date
		// whether the display supports reading brightness over DDC-CI
		private var canReadBrightness: Bool = true
		// brightness to be written to the display
		private var futureBrightness: Atomic<Float?>
		// task that saves the current settings to the display's internal memory
		private var saveCurrentSettingsTask: Atomic<DispatchWorkItem?>
		
		override init(fromDisplay displayID: CGDirectDisplayID) {
			// get the current and maximum brightness from the display, if possible, otherwise choose some sane values
			if let (curr, max) = DDC.read(.brightness, fromDisplay: displayID) {
				self.canReadBrightness = true
				self.brightness = Float(curr) / Float(max)
				self.brightnessScale = Float(max)
				self.lastSetOn = Date()
			}
			else {
				self.canReadBrightness = false
				self.brightness = 0.5
				self.brightnessScale = 100
				self.lastSetOn = Date.distantPast
			}
			
			self.futureBrightness = Atomic<Float?>(nil)
			self.saveCurrentSettingsTask = Atomic<DispatchWorkItem?>(nil)
			super.init(fromDisplay: displayID)
		}
		
		// step the brightness up or down, round to the nearest sixteenth or sixty-fourth
		override func stepBrightness(_ direction: StepDirection, inQuarterSteps useQuarterSteps: Bool = false) {
			var step: Float = direction.rawValue / 16.0
			let delta = step / 4
			if useQuarterSteps {
				step = delta
			}
			
			let currentBrightness: Float = self.futureBrightness.value ?? self.getBrightness()
			
			let newBrightness = ceil((currentBrightness + delta) / step) * step
			self.setBrightness(to: newBrightness)
		}
		
		override func changeBrightness(by delta: Float) {
			let currentBrightness: Float = self.futureBrightness.value ?? self.getBrightness()
			let newBrightness = currentBrightness + delta
			self.setBrightness(to: newBrightness)
		}
		
		override func setBrightness(to brightness: Float) {
			self.futureBrightness.value = min(max(0, brightness), 1)
			self.writeBrightness()
		}
		
		private func writeBrightness() {
			// write the brightness to the display over DDC-CI
			self.displayQueue.async {
				if let brightnessToWrite = self.futureBrightness.value {
					var success = false
					let newBrightness = UInt16(brightnessToWrite * self.brightnessScale)
					
					// with some displays, for example some Samsung ones, sometimes the DDC write command succeeds but the brightness doesn't change
					// try to perform the write multiple times in hope that one of them will actually change the brightness
					for _ in (1...5) {
						success = success || DDC.write(newBrightness, toControl: .brightness, toDisplay: self.displayID)
					}
					if success {
						self.brightness = brightnessToWrite
						self.lastSetOn = Date()
						BrightnessManager.showBrightnessHUD?(self.displayID, Int(self.brightness * 64), 64)
						// check if the user didn't request any new brightness change since the invocation of the write,
						// and if not, empty the future brightness value
						self.futureBrightness.mutate({ currentValue in
							currentValue == brightnessToWrite ? nil : currentValue
						})
						
						// create a task that instructs the display to save the current brightness into its internal memory
						// and execute that task two seconds from now
						// (saving the brightness into memory takes time and has a long associated delay, so we try to do that sparingly)
						let saveCurrentSettingsTask = DispatchWorkItem { DDC.saveCurrentSettings(ofDisplay: self.displayID) }
						self.displayQueue.asyncAfter(deadline: .now() + 2, execute: saveCurrentSettingsTask)
						
						// cancel the previous saving task if it hasn't executed yet, and store the new one
						self.saveCurrentSettingsTask.mutate({ currentTask in
							currentTask?.cancel()
							return saveCurrentSettingsTask
						})
					}
				}
			}
		}
		
		override func getBrightness() -> Float {
			// read the brightness over DDC-CI only if the display supports it,
			// and we last set it or read more than 10 seconds ago, so we don't read it directly too often because it's slow
			if self.canReadBrightness && (self.lastSetOn < Date(timeIntervalSinceNow: -10)) {
				if let curr = DDC.read(.brightness, fromDisplay: self.displayID)?.current {
					self.brightness = Float(curr) / self.brightnessScale
					self.lastSetOn = Date()
				}
			}
			return self.brightness
		}
	}
	
	// the display handler for each connected display
	private var displays: [CGDirectDisplayID: Display] = [:]
	
	internal var increaseBrightnessAction: KeyboardShortcutsManager.KeyAction?
	internal var decreaseBrightnessAction: KeyboardShortcutsManager.KeyAction?
	
	@objc internal dynamic var changeBrightnessOnAllDisplaysAtOnce: NSNumber = 1
	@objc internal dynamic var changeBrightnessOnAllDisplaysAtOnceRequiresCommand: NSNumber = 1
	
	@objc internal dynamic var decreaseBrightnessKey: NSString = "F9" {
		didSet {
			self.decreaseBrightnessAction?.key = self.decreaseBrightnessKey as String
		}
	}
	
	@objc internal dynamic var increaseBrightnessKey: NSString = "F10" {
		didSet {
			self.increaseBrightnessAction?.key = self.increaseBrightnessKey as String
		}
	}
	
	internal static let shared = BrightnessManager()
	
	override private init() {
		super.init()
		
		self.bind(NSBindingName(rawValue: "changeBrightnessOnAllDisplaysAtOnce"), to: NSUserDefaultsController.shared, withKeyPath: "values.changeBrightnessOnAllDisplaysAtOnce")
		self.bind(NSBindingName(rawValue: "changeBrightnessOnAllDisplaysAtOnceRequiresCommand"), to: NSUserDefaultsController.shared, withKeyPath: "values.changeBrightnessOnAllDisplaysAtOnceRequiresCommand")
		
		if KeyboardShortcutsManager.shared.isRegistered {
			self.bind(NSBindingName(rawValue: "decreaseBrightnessKey"), to: NSUserDefaultsController.shared, withKeyPath: "values.decreaseBrightnessKey")
			self.bind(NSBindingName(rawValue: "increaseBrightnessKey"), to: NSUserDefaultsController.shared, withKeyPath: "values.increaseBrightnessKey")
			
			self.decreaseBrightnessAction = KeyboardShortcutsManager.shared.addHandler(forKey: self.decreaseBrightnessKey as String, handler: self.decreaseBrightnessHandler)
			self.increaseBrightnessAction = KeyboardShortcutsManager.shared.addHandler(forKey: self.increaseBrightnessKey as String, handler: self.increaseBrightnessHandler)
		}
	}
	
	private func increaseBrightnessHandler(flags: CGEventFlags) {
		let optShiftPressed = flags.contains(.maskAlternate) && flags.contains(.maskShift)
		let commandPressed = flags.contains(.maskCommand)
		
		if self.changeBrightnessOnAllDisplaysAtOnce.boolValue && self.changeBrightnessOnAllDisplaysAtOnceRequiresCommand.boolValue == commandPressed {
			for displayID in type(of: self).getAllDisplayIDs() {
				self.increaseBrightness(onDisplay: displayID, useQuarterSteps: optShiftPressed)
			}
		}
		else {
			let displayID = type(of: self).getCurrentDisplayID()
			self.increaseBrightness(onDisplay: displayID, useQuarterSteps: optShiftPressed)
		}
	}
	
	private func decreaseBrightnessHandler(flags: CGEventFlags) {
		let optShiftPressed = flags.contains(.maskAlternate) && flags.contains(.maskShift)
		let commandPressed = flags.contains(.maskCommand)
		
		if self.changeBrightnessOnAllDisplaysAtOnce.boolValue && self.changeBrightnessOnAllDisplaysAtOnceRequiresCommand.boolValue == commandPressed {
			for displayID in type(of: self).getAllDisplayIDs() {
				self.decreaseBrightness(onDisplay: displayID, useQuarterSteps: optShiftPressed)
			}
		}
		else {
			let displayID = type(of: self).getCurrentDisplayID()
			self.decreaseBrightness(onDisplay: displayID, useQuarterSteps: optShiftPressed)
		}
	}
	
	internal func increaseBrightness(onDisplay displayID: CGDirectDisplayID, useQuarterSteps: Bool = false) {
		self.getDisplay(withID: displayID).increaseBrightness(inQuarterSteps: useQuarterSteps)
	}
	
	internal func decreaseBrightness(onDisplay displayID: CGDirectDisplayID, useQuarterSteps: Bool = false) {
		self.getDisplay(withID: displayID).decreaseBrightness(inQuarterSteps: useQuarterSteps)
	}
	
	private func getDisplay(withID displayID: CGDirectDisplayID) -> Display {
		if let display = self.displays[displayID] {
			return display
		}
		else {
			var display: Display
			if type(of: self).DisplayServicesCanChangeBrightness?(displayID) ?? false {
				display = InternalDisplay(fromDisplay: displayID)
			}
			else {
				display = ExternalDisplay(fromDisplay: displayID)
			}
			self.displays[displayID] = display
			return display
		}
	}
	
	internal static func getCurrentDisplayID() -> CGDirectDisplayID {
		return NSScreen.main?.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID ?? 0
	}
	
	internal static func getAllDisplayIDs() -> [CGDirectDisplayID] {
		return NSScreen.screens.map { $0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
	}
	
	// shows the brightness HUD with the correct brightness indicator on the correct display
	// unfortunately Apple doesn't provide a public API for this, so we have to manually extract the function from the OSD framework
	private static var showBrightnessHUD: ((CGDirectDisplayID, Int, Int) -> Void)? {
		if let osdLoaded = Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework")?.load(), osdLoaded {
			if let sharedOSDManager = NSClassFromString("OSDManager")?.value(forKeyPath: "sharedManager") as AnyObject? {
				let showImageSelector = Selector(("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"))
				if sharedOSDManager.responds(to: showImageSelector) {
					let showImageImplementation = sharedOSDManager.method(for: showImageSelector)
					
					typealias ShowImageFunctionType = @convention(c) (AnyObject, Selector, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
					let showImage = unsafeBitCast(showImageImplementation, to: ShowImageFunctionType.self)
					
					return {(onDisplayID: CGDirectDisplayID, filledChiclets: Int, totalChiclets: Int) -> Void in
						showImage(sharedOSDManager, showImageSelector, 1, onDisplayID, 0x1f3, 1000, UInt32(filledChiclets), UInt32(totalChiclets), false)
					}
				}
			}
		}
		return nil
	}
	
	// determines whether the brightness of the specified display can be manipulated through the CoreDisplay framework
	// unfortunately Apple doesn't provide a public API for this, so we have to manually extract the function from the DisplayServices framework
	private static var DisplayServicesCanChangeBrightness: ((CGDirectDisplayID) -> Bool)? {
		let displayServicesPath = CFURLCreateWithString(kCFAllocatorDefault, "/System/Library/PrivateFrameworks/DisplayServices.framework" as CFString, nil)
		if let displayServicesBundle = CFBundleCreate(kCFAllocatorDefault, displayServicesPath) {
			if let funcPointer = CFBundleGetFunctionPointerForName(displayServicesBundle, "DisplayServicesCanChangeBrightness" as CFString) {
				typealias DSCCBFunctionType = @convention(c) (UInt32) -> Bool
				return unsafeBitCast(funcPointer, to: DSCCBFunctionType.self)
			}
		}
		return nil
	}
}

// An atomic variable, used for thread-safe brightness manipulation
private class Atomic<T> {
	private let semaphore = DispatchSemaphore(value: 1)
	private var _value: T
	var value: T {
		get {
			semaphore.wait()
			defer { semaphore.signal() }
			return _value
		}
		set {
			semaphore.wait()
			defer { semaphore.signal() }
			_value = newValue
		}
	}
	init(_ value: T) {
		semaphore.wait()
		defer { semaphore.signal() }
		_value = value
	}
	
	func perform(_ operation: (_ current: T) -> Void) {
		semaphore.wait()
		defer { semaphore.signal() }
		operation(_value)
	}
	
	func mutate(_ mutation: (_ current: T) -> (T)) {
		semaphore.wait()
		defer { semaphore.signal() }
		_value = mutation(_value)
	}
}
