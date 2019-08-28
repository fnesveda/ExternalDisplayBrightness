import Foundation

// Manages the login item for the application
// Used as a singleton via LoginItemManager.shared
// To be utilized by either changing the .isEnabled property directly,
// or by binding to it (possibly using LoginItemCheckboxTransformer as ValueTransformer)
// Manipulates the login item list in System Preferences -> User -> Login Items via a deprecated API
internal class LoginItemManager: NSObject {
	internal static let shared = LoginItemManager()
	
	override private init() {
		super.init()
		registerValueTransformer()
	}
	
	private func registerValueTransformer() {
		ValueTransformer.setValueTransformer(LoginItemCheckboxTransformer(), forName: .loginItemCheckboxTransformerName)
	}
	
	private static func getLoginItemsRef() -> LSSharedFileList? {
		return LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeRetainedValue(), nil)?.takeRetainedValue()
	}
	
	private static func findLoginItem(loginItemsRef: LSSharedFileList?) -> LSSharedFileListItem? {
		if loginItemsRef != nil {
			var seedValue: UInt32 = 0
			if let loginItemsList = LSSharedFileListCopySnapshot(loginItemsRef, &seedValue)?.takeRetainedValue() as? [LSSharedFileListItem] {
				for item in loginItemsList {
					if let pathURL = LSSharedFileListItemCopyResolvedURL(item, 0, nil)?.takeRetainedValue() {
						if let path = CFURLCopyPath(pathURL) as NSString? {
							if path.hasPrefix(Bundle.main.bundlePath) {
								return item
							}
						}
					}
				}
			}
		}
		return nil
	}
	
	@objc internal dynamic var isEnabled: Bool {
		get {
			let loginItemsRef = type(of: self).getLoginItemsRef()
			let loginItem = type(of: self).findLoginItem(loginItemsRef: loginItemsRef)
			return loginItem != nil
		}
		set {
			let loginItemsRef = type(of: self).getLoginItemsRef()
			let loginItem = type(of: self).findLoginItem(loginItemsRef: loginItemsRef)
			
			if (loginItem != nil) != newValue {
				if newValue {
					let appURL = URL(fileURLWithPath: Bundle.main.bundlePath) as CFURL
					LSSharedFileListInsertItemURL(loginItemsRef, nil, nil, nil, appURL, nil, nil)
				}
				else {
					LSSharedFileListItemRemove(loginItemsRef, loginItem)
				}
			}
		}
	}
	
	internal func updateEnabled() {
		self.willChangeValue(forKey: "isEnabled")
		self.didChangeValue(forKey: "isEnabled")
	}
}

// A value transformer to be used when binding a checkbox cell to .isEnabled
@objc(LoginItemCheckboxTransformer)
internal class LoginItemCheckboxTransformer: ValueTransformer {
	override class func transformedValueClass() -> AnyClass {
		return NSNumber.self
	}
	
	override class func allowsReverseTransformation() -> Bool {
		return true
	}
	
	override func transformedValue(_ value: Any?) -> Any? {
		let boolValue = value as? Bool ?? false
		return NSNumber(value: boolValue)
	}
	
	override func reverseTransformedValue(_ value: Any?) -> Any? {
		return value as? NSNumber ?? NSNumber(value: 0)
	}
}

extension NSValueTransformerName {
	static let loginItemCheckboxTransformerName = NSValueTransformerName(rawValue: LoginItemCheckboxTransformer.className())
}
