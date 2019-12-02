import Foundation
import IOKit.i2c

// Utility for reading control values from and writing control values to an external display over DDC-CI
// Adapted from www.github.com/kfix/ddcctl, cleaned up to only support brightness changes (for now)
enum DDC {
	// IDs of different controls available to change over DDC-CI
	enum Control: UInt8 {
		case brightness = 0x10
		case settings = 0xB0
	}
	
	// operation queues for each display, used to avoid multiple operations on the same display at once
	private static var displayDispatchQueues: [CGDirectDisplayID: DispatchQueue] = [CGDirectDisplayID: DispatchQueue]()
	private static func getDispatchQueue(forDisplayID displayID: CGDirectDisplayID) -> DispatchQueue {
		if let queue = displayDispatchQueues[displayID] {
			return queue
		}
		else {
			let queue = DispatchQueue(label: "DDC-\(String(displayID))-\(UUID().uuidString)")
			displayDispatchQueues[displayID] = queue
			return queue
		}
	}
	
	// check if the display connected to a given framebuffer port appears to be the same one as the display with the given ID
	// if requested, check the unit number of the display as well
	private static func framebufferPortMatchesDisplay(port: io_service_t, display displayID: CGDirectDisplayID, strict: Bool = true) -> Bool {
		var busCount: IOItemCount = 0
		IOFBGetI2CInterfaceCount(port, &busCount)
		if busCount >= 1 {
			let info = IODisplayCreateInfoDictionary(port, IOOptionBits(kIODisplayNoProductName)).takeRetainedValue() as NSDictionary
			let vendorID     = UInt32(bitPattern: Int32(exactly: info[kDisplayVendorID]     as? CFIndex ?? 0) ?? 0)
			let productID    = UInt32(bitPattern: Int32(exactly: info[kDisplayProductID]    as? CFIndex ?? 0) ?? 0)
			// we could also extract and compare the serial number, but they are often wrong and identical for multiple displays of the same model
			if vendorID == CGDisplayVendorNumber(displayID)	&& productID == CGDisplayModelNumber(displayID) {
				if !strict {
					return true
				}
				
				// extract the unit number from the display location path from the I/O registry dictionary of the framebuffer
				// and compare it with the unit number of the desired display
				// this comparison on its own should probably be enough, but since I don't have enough hardware to test it,
				// it's only an optional check for now
				if let displayLocation = info[kIODisplayLocationKey] as? NSString {
					// the unit number is the number right after the last "@" sign in the display location
					if let regex = try? NSRegularExpression(pattern: "@([0-9]+)[^@]+$", options: []) {
						if let match = regex.firstMatch(in: displayLocation as String, options: [], range: NSRange(location: 0, length: displayLocation.length)) {
							let unitNumber = UInt32(displayLocation.substring(with: match.range(at: 1)))
							if unitNumber == CGDisplayUnitNumber(displayID) {
								return true
							}
						}
					}
				}
			}
		}
		return false
	}
	
	// get framebuffer port for a display
	private static func getIOFramebufferPort(fromDisplayID displayID: CGDirectDisplayID ) -> io_service_t? {
		if CGDisplayIsBuiltin(displayID) != 0 {
			return nil
		}
		
		var iter: io_iterator_t = 0
		if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(IOFRAMEBUFFER_CONFORMSTO), &iter) == kIOReturnSuccess {
			defer { IOObjectRelease(iter) }
			
			// try to find the right framebuffer port for the display by looking at all framebuffer ports
			// and seeing if any of them appears to have the right display connected to it
			// first we do a strict comparison (vendor, model and unit numbers of the desired display and the display connected to the framebuffer must match)
			var serv: io_service_t = 0
			while (serv = IOIteratorNext(iter), serv).1 != MACH_PORT_NULL {
				defer { IOObjectRelease(serv) }
				if framebufferPortMatchesDisplay(port: serv, display: displayID, strict: true) {
					IOObjectRetain(serv)
					return serv
				}
			}
			// since the method for extracting the unit number of a display is new and untested, we have a fallback check
			// where we relax the requirements and only search for a framebuffer port with a connected display with the matching vendor and model number
			IOIteratorReset(iter)
			while (serv = IOIteratorNext(iter), serv).1 != MACH_PORT_NULL {
				defer { IOObjectRelease(serv) }
				if framebufferPortMatchesDisplay(port: serv, display: displayID, strict: false) {
					IOObjectRetain(serv)
					return serv
				}
			}
		}
		return nil
	}
	
	// get supported I2C / DDC transaction types
	// DDCciReply is what we want, but Simple will also work
	private static func getSupportedTransactionType() -> UInt32 {
		var ioObjects: io_iterator_t = 0
		var ioService: io_service_t = 0
		var supportedType: UInt32 = 0
		
		if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceNameMatching("IOFramebufferI2CInterface"), &ioObjects) == kIOReturnSuccess {
			while (ioService = IOIteratorNext(ioObjects), ioService).1 != MACH_PORT_NULL {
				defer { IOObjectRelease(ioService) }
				var serviceProperties: Unmanaged<CFMutableDictionary>?
				
				if IORegistryEntryCreateCFProperties(ioService, &serviceProperties, kCFAllocatorDefault, 0)	== kIOReturnSuccess {
					if let sp = serviceProperties?.takeRetainedValue() {
						if let types = ((sp as NSDictionary as? [String: Any])?[kIOI2CTransactionTypesKey] as? Int) {
							if types != 0 {
								if ((1 << kIOI2CDDCciReplyTransactionType) & types) != 0 {
									supportedType = UInt32(kIOI2CDDCciReplyTransactionType)
								}
								else if ((1 << kIOI2CSimpleTransactionType) & types) != 0 {
									supportedType = UInt32(kIOI2CSimpleTransactionType)
								}
							}
						}
					}
				}
			}
		}
		return supportedType
	}
	
	// send an I2C request to a display
	@discardableResult
	private static func sendRequest(_ request: UnsafeMutablePointer<IOI2CRequest>, toDisplay displayID: CGDirectDisplayID, withPostRequestDelay postRequestDelay: UInt32 = 0) -> Bool {
		let displayQueue = getDispatchQueue(forDisplayID: displayID)
		var result = false
		displayQueue.sync {
			if let framebufferPort: io_service_t = getIOFramebufferPort(fromDisplayID: displayID) {
				defer { IOObjectRelease(framebufferPort) }
				var busCount: io_service_t = 0
				if IOFBGetI2CInterfaceCount(framebufferPort, &busCount) == kIOReturnSuccess {
					for bus: IOOptionBits in 0..<busCount {
						var interface: io_service_t = 0
						if IOFBCopyI2CInterfaceForBus(framebufferPort, bus, &interface) == kIOReturnSuccess {
							defer { IOObjectRelease(interface) }
							var connect: IOI2CConnectRef?
							if IOI2CInterfaceOpen(interface, 0, &connect) == kIOReturnSuccess {
								defer { IOI2CInterfaceClose(connect, 0) }
								if IOI2CSendRequest(connect, 0, request) == kIOReturnSuccess {
									result = request.pointee.result == kIOReturnSuccess
									break
								}
							}
						}
					}
				}
			}
			usleep(postRequestDelay * 1000)
		}
		return result
	}
	
	// write a value to a control of a display
	@discardableResult
	static func write(_ value: UInt16, toControl controlID: Control, toDisplay displayID: CGDirectDisplayID) -> Bool {
		var data = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 128)
		defer { data.deallocate() }
		
		var request = IOI2CRequest()
		request.commFlags = 0
		request.sendAddress = 0x6E
		request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
		request.sendBuffer = vm_address_t(bitPattern: data.baseAddress)
		request.sendBytes = 7
		
		data[0] = 0x51
		data[1] = 0x84
		data[2] = 0x03
		data[3] = controlID.rawValue
		data[4] = UInt8(value >> 8)
		data[5] = UInt8(value & 0x00FF)
		data[6] = 0x6E ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4] ^ data[5]
		
		request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
		request.replyBytes = 0
		return sendRequest(&request, toDisplay: displayID, withPostRequestDelay: 50)
	}
	
	// read the current and maximum value of a control of a display
	static func read(_ controlID: Control, fromDisplay displayID: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
		var data = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 128)
		var replyData = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 11)
		defer {
			data.deallocate()
			replyData.deallocate()
		}
		
		var request = IOI2CRequest()
		request.commFlags = 0
		request.sendAddress = 0x6E
		request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
		request.sendBuffer = vm_address_t(bitPattern: data.baseAddress)
		request.sendBytes = 5
		// reply delay set according to the DDC/CI standard, Section 6.6 I2C Bus Timings
		request.minReplyDelay = UInt64(40 * kMillisecondScale)
		
		data[0] = 0x51
		data[1] = 0x82
		data[2] = 0x01
		data[3] = controlID.rawValue
		data[4] = 0x6E ^ data[0] ^ data[1] ^ data[2] ^ data[3]
		
		request.replyTransactionType = getSupportedTransactionType()
		request.replyAddress = 0x6F
		request.replySubAddress = 0x51
		
		request.replyBuffer = vm_address_t(bitPattern: replyData.baseAddress)
		request.replyBytes = UInt32(replyData.count)
		
		if sendRequest(&request, toDisplay: displayID, withPostRequestDelay: 40) {
			var checksum = UInt8(request.replyAddress)
			checksum = checksum ^ request.replySubAddress
			checksum = checksum ^ replyData[1] ^ replyData[2] ^ replyData[3]
			checksum = checksum ^ replyData[4] ^ replyData[5] ^ replyData[6]
			checksum = checksum ^ replyData[7] ^ replyData[8] ^ replyData[9]
			if replyData[0] == request.sendAddress && replyData[2] == 0x2 && replyData[4] == controlID.rawValue && replyData[10] == checksum {
				let current = UInt16(replyData[8]) << 8 + UInt16(replyData[9])
				let max = UInt16(replyData[6]) << 8 + UInt16(replyData[7])
				return (current, max)
			}
		}
		
		return nil
	}
	
	// save the current display settings to the display's internal memory (to survive turning off and on)
	@discardableResult
	static func saveCurrentSettings(ofDisplay displayID: CGDirectDisplayID) -> Bool {
		return write(1, toControl: .settings, toDisplay: displayID)
	}
}
