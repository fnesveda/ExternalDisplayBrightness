import Foundation
import IOKit.i2c

// Utility for reading control values from and writing control values to an external display over DDC-CI
// Adapted from www.github.com/kfix/ddcctl, cleaned up to only support brightness changes (for now)
enum DDC {
	// IDs of different controls available to change over DDC-CI
	enum Control: UInt8 {
		case brightness = 0x10
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
	
	// get framebuffer port for a display
	private static func getIOFramebufferPort(fromDisplayID displayID: CGDirectDisplayID ) -> io_service_t? {
		if CGDisplayIsBuiltin(displayID) != 0 {
			return nil
		}
		var iter: io_iterator_t = 0
		var serv: io_service_t = 0
		
		if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(IOFRAMEBUFFER_CONFORMSTO), &iter) == kIOReturnSuccess {
			defer { IOObjectRelease(iter) }
			while (serv = IOIteratorNext(iter), serv).1 != MACH_PORT_NULL {
				defer { IOObjectRelease(serv) }
				var busCount: IOItemCount = 0
				IOFBGetI2CInterfaceCount(serv, &busCount)
				if busCount >= 1 {
					if let info = IODisplayCreateInfoDictionary(serv, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as NSDictionary as? [String: Any] {
						if let vendorID = info[kDisplayVendorID] as? UInt32, let productID = info[kDisplayProductID] as? UInt32 {
							let serialNumber = info[kDisplaySerialNumber] as? UInt32 ?? 0
							if vendorID == CGDisplayVendorNumber(displayID)
								&& productID == CGDisplayModelNumber(displayID)
								&& (serialNumber == 0 || serialNumber == CGDisplaySerialNumber(displayID))
							{
								IOObjectRetain(serv)
								return serv
							}
						}
					}
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
	static func write(_ value: UInt8, toControl controlID: Control, toDisplay displayID: CGDirectDisplayID) -> Bool {
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
		data[4] = value >> 8
		data[5] = value & 0xFF
		data[6] = 0x6E ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4] ^ data[5]
		
		request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
		request.replyBytes = 0
		return sendRequest(&request, toDisplay: displayID, withPostRequestDelay: 50)
	}
	
	// read the current and maximum value of a control of a display
	static func read(_ controlID: Control, fromDisplay displayID: CGDirectDisplayID) -> (current: UInt8, max: UInt8)? {
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
		request.minReplyDelay = UInt64(10 * kMillisecondScale)  // too short can freeze kernel
		
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
				return (replyData[9], replyData[7])
			}
		}
		
		return nil
	}
}
