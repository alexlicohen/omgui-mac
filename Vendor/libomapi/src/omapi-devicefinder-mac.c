// make && gcc -o test -I../include -Dtest_main=main test.c -lpthread -L. -lomapi -framework CoreFoundation -framework IOKit -framework DiskArbitration
// /dev/tty.usbmodem* /dev/cu.usbmodem*
// /Volumes/AX317_?????
// ioreg -p IOUSB -l -b
/* 
 * Copyright (c) 2009-, Newcastle University, UK.
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without 
 * modification, are permitted provided that the following conditions are met: 
 * 1. Redistributions of source code must retain the above copyright notice, 
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice, 
 *    this list of conditions and the following disclaimer in the documentation 
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
 * POSSIBILITY OF SUCH DAMAGE. 
 */

// Open Movement API - Device Discovery (Mac OS)
// Dan Jackson, 2011-

// Some code based on "USBPrivateDataSample" by Apple.
// Some code based on "Get USB Drive Serial Number on Os X in C++": https://oroboro.com/usb-serial-number-osx/

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>

#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#include <DiskArbitration/DiskArbitration.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <errno.h>
#include <paths.h>
#include <sys/param.h>
#include <mach/mach.h>
#include <mach/error.h>

// #include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
// #include <IOKit/usb/IOUSBLib.h>

#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOCDMedia.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IOCDTypes.h>
#include <IOKit/storage/IOMediaBSDClient.h>

#include <IOKit/serial/IOSerialKeys.h>
#include <IOKit/serial/ioss.h>

#include <ctype.h>
#include <sys/stat.h>
#include <sys/time.h>		// PATCH (omgui-mac) C17: gettimeofday() for the bounded stop


#include "omapi-internal.h"

#define VID 0x04D8
#define PID 0x0057

typedef struct DeviceData
{
	io_object_t notification;
	IOUSBDeviceInterface **deviceInterface;
	CFStringRef deviceName;
	UInt32 locationID;
	const char *serialNumber;
	unsigned int deviceId;
	const char *mountPath;
	const char *serialDevice;
	struct DeviceData *next;		// PATCH (omgui-mac) L1: registry of the live records
} DeviceData;

static IONotificationPortRef gNotifyPort;
static io_iterator_t gAddedIter;
static CFRunLoopRef gRunLoop;

// PATCH (omgui-mac) L1: every DeviceData is owned by the kIOGeneralInterest notification armed for
// it and is released only inside DeviceNotification().  Stop() destroys the notification port,
// after which that callback can never fire, so each stop/start cycle leaked one DeviceData and the
// ~1.2 KB of strings it owns for every attached device.  They are chained here so Stop() can run
// the same epilogue itself before the port goes.  The list is only ever touched from the discovery
// run-loop thread (DeviceAdded and DeviceNotification both run on it) and from Stop() *after* that
// thread has been joined, so it needs no lock -- and Stop() must not touch it at all on the path
// where the thread was orphaned rather than joined.
static DeviceData *gDeviceDataList;

// PATCH (omgui-mac) H4: sticky once Stop() has given up on the discovery thread.  See
// OmDeviceDiscoveryDetached() in omapi-internal.h.
static volatile int gDiscoveryDetached;

int OmDeviceDiscoveryDetached(void)
{
	return gDiscoveryDetached;
}

/** PATCH (omgui-mac) C6/C36/L1: the single release epilogue for a DeviceData, shared by the
 *  removal notification, the DeviceAdded() failure path, and Stop().  Upstream leaked the
 *  deviceName CFString, the device interface and all three heap strings on failure. */
static void DeviceDataRelease(DeviceData *deviceData)
{
	if (deviceData == NULL) { return; }
	if (deviceData->notification) { IOObjectRelease(deviceData->notification); }
	if (deviceData->deviceName) { CFRelease(deviceData->deviceName); }
	if (deviceData->deviceInterface)
	{
		(*deviceData->deviceInterface)->Release(deviceData->deviceInterface);
	}
	free((void *)deviceData->serialNumber);
	free((void *)deviceData->mountPath);
	free((void *)deviceData->serialDevice);
	free(deviceData);
}

/** Take a registered DeviceData out of the list (no-op if it was never registered). */
static void DeviceDataUnlink(DeviceData *deviceData)
{
	DeviceData **link;
	for (link = &gDeviceDataList; *link != NULL; link = &(*link)->next)
	{
		if (*link == deviceData) { *link = deviceData->next; deviceData->next = NULL; return; }
	}
}

// PATCH (omgui-mac): cfStringRefToCString() removed -- its only caller was the rewritten findMount().


// Does this mounted volume hold an AX3/AX6 data file?
static int volumeHasDataFile(const char *volumePath)
{
	char dataFile[PATH_MAX];
	struct stat st;
	if (volumePath == NULL || volumePath[0] == '\0') { return 0; }
	snprintf(dataFile, sizeof(dataFile), "%s/%s", volumePath, OM_DEFAULT_FILENAME);
	return (stat(dataFile, &st) == 0) ? 1 : 0;
}

// Mount point for one BSD device node ("/dev/diskNsM"), or NULL.  Caller frees.
static char *mountPathForBsdName(DASessionRef daSession, const char *bsdName)
{
	char *volumePath = NULL;
	DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, daSession, bsdName);
	if (disk == NULL) { return NULL; }
	CFDictionaryRef desc = DADiskCopyDescription(disk);
	if (desc != NULL)
	{
		CFURLRef url = (CFURLRef)CFDictionaryGetValue(desc, kDADiskDescriptionVolumePathKey);
		if (url != NULL)
		{
			char buffer[PATH_MAX];
			buffer[0] = '\0';
			if (CFURLGetFileSystemRepresentation(url, true, (UInt8 *)buffer, sizeof(buffer)) && buffer[0] != '\0')
			{
				// Mount paths are reported with a trailing slash ("/Volumes/AX317_12345/")
				size_t len = strlen(buffer);
				while (len > 1 && buffer[len - 1] == '/') { buffer[--len] = '\0'; }
				volumePath = strdup(buffer);
			}
		}
		CFRelease(desc);
	}
	CFRelease(disk);
	return volumePath;
}

// Find the mounted volume that holds this device's data file.
//
// PATCH (omgui-mac): upstream recovered the volume *name* by string-scanning CFCopyDescription()
// output, assumed the mount point was always "/Volumes/<name>", and assumed the data partition
// was always "<disk>s1".  All three are unsafe: a volume name is not a mount point (duplicates
// get " 1" appended by the mounter and names may contain '/'), some units present a
// "superfloppy" with no partition table so the volume *is* the whole disk, and the AX6 does not
// use the AX317_ label the upstream comment assumed.  We now ask DiskArbitration for the real
// mount path (kDADiskDescriptionVolumePathKey) and select the volume by the presence of
// CWA-DATA.CWA.  The CF objects that upstream leaked here are also released.
static const char *findMount(io_service_t usbDevice)
{
	char *volumePath = NULL;
	io_name_t className;
	CFStringRef bsdNameRef = NULL;
	DASessionRef daSession;
	char wholeDisk[64];
	int attempt;

	OmLog(3, "MAC: usbDevice: %u\n", (unsigned int)usbDevice);
	if (!IOObjectConformsTo(usbDevice, "IOUSBDevice") && !IOObjectConformsTo(usbDevice, "IOUSBHostDevice")) { return NULL; }
	IOObjectGetClass(usbDevice, className);
	OmLog(3, "MAC: ...className: %s\n", (const char *)className);

	daSession = DASessionCreate(kCFAllocatorDefault);
	if (daSession == NULL) { OmLog(0, "MAC: ERROR: DASessionCreate failed.\n"); return NULL; }

	wholeDisk[0] = '\0';

	// The mass-storage interface enumerates and mounts a moment after the USB device appears.
	for (attempt = 0; attempt < 160 && volumePath == NULL; attempt++)		// up to ~8 seconds
	{
		if (om.quitDiscoveryThread) { break; }

		if (bsdNameRef == NULL)
		{
			bsdNameRef = (CFStringRef)IORegistryEntrySearchCFProperty(usbDevice, kIOServicePlane, CFSTR(kIOBSDNameKey), kCFAllocatorDefault, kIORegistryIterateRecursively);
			if (bsdNameRef != NULL)
			{
				char bsdName[64];
				size_t len;
				bsdName[0] = '\0';
				CFStringGetCString(bsdNameRef, bsdName, sizeof(bsdName), kCFStringEncodingUTF8);
				OmLog(3, "MAC: ...bsd name: %s\n", bsdName);
				// Reduce a partition node "diskNsM" to the whole disk "diskN"
				strncpy(wholeDisk, bsdName, sizeof(wholeDisk) - 1);
				wholeDisk[sizeof(wholeDisk) - 1] = '\0';
				len = strlen(wholeDisk);
				while (len > 0 && isdigit((unsigned char)wholeDisk[len - 1])) { len--; }
				if (len > 0 && wholeDisk[len - 1] == 's') { wholeDisk[len - 1] = '\0'; }
			}
		}

		if (wholeDisk[0] != '\0')
		{
			// Whole disk first (superfloppy), then the first few partitions
			char *fallback = NULL;
			int part;
			for (part = 0; part <= 4 && volumePath == NULL; part++)
			{
				char candidate[96];
				char *mount;
				if (part == 0) { snprintf(candidate, sizeof(candidate), "/dev/%s", wholeDisk); }
				else { snprintf(candidate, sizeof(candidate), "/dev/%ss%d", wholeDisk, part); }
				mount = mountPathForBsdName(daSession, candidate);
				if (mount == NULL) { continue; }
				OmLog(3, "MAC: ...%s is mounted at: %s\n", candidate, mount);
				if (volumeHasDataFile(mount)) { volumePath = mount; }
				else if (fallback == NULL) { fallback = mount; }
				else { free(mount); }
			}
			// Mounted but no data file yet: keep polling, and only then accept it anyway
			// (a device can be seen briefly between a FORMAT and the new data file appearing).
			if (volumePath == NULL && fallback != NULL && attempt >= 60)
			{
				OmLog(0, "MAC: WARNING: Volume %s has no %s -- accepting it anyway.\n", fallback, OM_DEFAULT_FILENAME);
				volumePath = fallback;
				fallback = NULL;
			}
			if (fallback != NULL) { free(fallback); }
		}

		if (volumePath == NULL) { usleep(50 * 1000); }
	}

	if (bsdNameRef != NULL) { CFRelease(bsdNameRef); }
	CFRelease(daSession);
	if (volumePath != NULL) { OmLog(3, "MAC: ...volume: %s\n", volumePath); }
	return volumePath;
}

static const char *getUSBStringDescriptor(IOUSBDeviceInterface182 **usbDevice, UInt8 idx)
{
	UInt16 buffer[64];
	IOUSBDevRequest request;
	request.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
	request.bRequest = kUSBRqGetDescriptor;
	request.wValue = (kUSBStringDesc << 8) | idx;
	request.wIndex = 0x409; // english
	request.wLength = sizeof( buffer );
	request.pData = buffer;

	kern_return_t err = (*usbDevice)->DeviceRequest(usbDevice, &request);
	if (err != 0) 
	{
		OmLog(2, "ERROR: DeviceRequest failed.\n");
		return NULL;
	}
  
	// PATCH (omgui-mac) C14: wLenDone is unsigned, so a device that ACKs the request with a
	// zero-length descriptor (a re-enumerating AX3 right after a FORMAT) made (wLenDone - 1) / 2
	// wrap to 0x7FFFFFFF and the loop below write 2.1 billion bytes into a 128-byte heap buffer.
	// Reject a descriptor too short to hold anything, clamp the count to what both `buffer` and
	// the allocation can hold, and check the allocation.
	if (request.wLenDone < 2)
	{
		OmLog(2, "ERROR: DeviceRequest returned a %u-byte string descriptor.\n", (unsigned int)request.wLenDone);
		return NULL;
	}
	int count = (int)((request.wLenDone - 1) / 2);
	if (count > (int)(sizeof(buffer) / sizeof(buffer[0])) - 1) { count = (int)(sizeof(buffer) / sizeof(buffer[0])) - 1; }
	if (count > 127) { count = 127; }
	char *stringValue = malloc(128);
	if (stringValue == NULL) { return NULL; }
	int i;
	for (i = 0; i < count; i++)
	{
		stringValue[i] = buffer[i+1];
	}
	stringValue[i] = '\0'; 
	return stringValue;
}

static unsigned int DeviceIdFromSerialNumber(const char *serialNumber)
{
	// Return the number found at the end of the string (0 if none)
	bool inNumber = false;
    unsigned int value = 0;		// PATCH (omgui-mac): was (unsigned)-1, which the caller's "<= 0" test could never catch
    const char *p;
    for (p = serialNumber; *p != 0; p++)
    {
		if (*p >= '0' && *p <= '9')
		{
			if (!inNumber) { inNumber = true; value = 0; }
			value = (10 * value) + (*p - '0');
		}
		else inNumber = false;
    }
    return value;
}

static const char *getUSBSerialNumber(io_service_t usbDevice)
{
	SInt32 score;
	IOCFPlugInInterface **plugin;
	IOUSBDeviceInterface182 **usbDevice182 = NULL;
	kern_return_t err;
	err = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
	if (err != 0) 
	{
		OmLog(2, "ERROR: IOCreatePlugInInterfaceForService failed.\n");
		return NULL;
	}
	err = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (void **)&usbDevice182);
	IODestroyPlugInInterface(plugin);
	if (err != 0) 
	{
		OmLog(2, "ERROR: IODestroyPlugInInterface failed.\n");
		return NULL;
	}

	// UInt8 vidIdx;
	// (*usbDevice182)->USBGetManufacturerStringIndex(usbDevice182, &vidIdx);
	// getUSBStringDescriptor(usbDevice182, vidIdx);

	// UInt8 pidIdx;
	// (*usbDevice182)->USBGetProductStringIndex(usbDevice182, &pidIdx);
	// getUSBStringDescriptor(usbDevice182, pidIdx));

	// UInt16 rev;
	// (*usbDevice182)->GetDeviceReleaseNumber(usbDevice182, &rev);
	// rev

	UInt8 snIdx;
	(*usbDevice182)->USBGetSerialNumberStringIndex(usbDevice182, &snIdx);
	if (snIdx <= 0) return NULL; // What is the index actually set to if there is no serial number?
	return getUSBStringDescriptor(usbDevice182, snIdx);
}

// Find the serial port path for the specified USB serial ID string
const char *findSerial(const char *usbSerial)
{
	char *serialPath = NULL;

	CFMutableDictionaryRef classes;
	if (!(classes = IOServiceMatching(kIOSerialBSDServiceValue)))
	{
		OmLog(2, "ERROR: IOServiceMatching failed.\n");
		return NULL;
	}

	io_iterator_t iter;
	if (IOServiceGetMatchingServices(kIOMainPortDefault, classes, &iter) != KERN_SUCCESS)		// PATCH (omgui-mac): kIOMasterPortDefault deprecated in macOS 12
	{
		OmLog(2, "ERROR: IOServiceGetMatchingServices failed.\n");
		return NULL;
	}

	io_object_t ioport;
	while ((ioport = IOIteratorNext(iter)))
	{
		CFTypeRef cf_property;
		if (!(cf_property = IORegistryEntryCreateCFProperty(ioport, CFSTR(kIOCalloutDeviceKey), kCFAllocatorDefault, 0)))
		{
			OmLog(2, "WARNING: IORegistryEntryCreateCFProperty failed.\n");
			IOObjectRelease(ioport);
			continue;
		}
		char path[PATH_MAX];
		Boolean result = CFStringGetCString(cf_property, path, sizeof(path), kCFStringEncodingASCII);
		//OmLog(3, "MAC: io path: %s\n", path);
		CFRelease(cf_property);
		if (!result)
		{
			OmLog(2, "WARNING: CFStringGetCString failed.\n");
			IOObjectRelease(ioport);
			continue;
		}

		if ((cf_property = IORegistryEntrySearchCFProperty(ioport, kIOServicePlane, CFSTR("USB Serial Number"), kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents)))
		{
			char serial[128];
			if (CFStringGetCString(cf_property, serial, sizeof(serial), kCFStringEncodingASCII))
			{
				//OmLog(3, "MAC: ...compare serial: %s = %u\n", serial, usbSerial);
				if (strcmp(serial, usbSerial) == 0) {
					serialPath = malloc(PATH_MAX);
					strcpy(serialPath, path);
					OmLog(3, "MAC: Found serial number %s at path: %s\n", serial, path);
					// PATCH (omgui-mac): upstream broke out here leaking cf_property and ioport
					CFRelease(cf_property);
					IOObjectRelease(ioport);
					break;
				}
			}
			CFRelease(cf_property);
		}

		IOObjectRelease(ioport);
	}
	IOObjectRelease(iter);
	return serialPath;
}

// Called on kIOGeneralInterest notification, look for kIOMessageServiceIsTerminated (IOMessage.h)
static void DeviceNotification(void *refCon, io_service_t service, natural_t messageType, void *messageArgument)
{
	DeviceData *deviceData = (DeviceData *)refCon;
	if (messageType == kIOMessageServiceIsTerminated)
	{		
		OmLog(2, "MAC: Removed %u\n", deviceData->deviceId);
		OmLog(3, "->deviceName: "); CFShow(deviceData->deviceName);
		OmLog(3, "->locationID: 0x%lx.\n", deviceData->locationID);
		OmLog(3, "->deviceId: 0x%x.\n", deviceData->deviceId);

		// Call device removed
		OmDeviceDiscovery(OM_DEVICE_REMOVED, deviceData->deviceId, deviceData->serialNumber, deviceData->serialDevice, deviceData->mountPath);

		// PATCH (omgui-mac) C36/L1: upstream leaked all three heap strings on every detach
		// (getUSBStringDescriptor() malloc()s, findMount() strdup()s, findSerial() malloc()s),
		// i.e. ~1.2 KB per attach/detach cycle on the app's hot path.
		DeviceDataUnlink(deviceData);
		DeviceDataRelease(deviceData);
	}
}

// IOServiceAddMatchingNotification - device added
static void DeviceAdded(void *refCon, io_iterator_t iterator)
{
	kern_return_t kr;
	io_service_t usbDevice;
	IOCFPlugInInterface **plugInInterface = NULL;
	SInt32 score;
	HRESULT res;
	
	while ((usbDevice = IOIteratorNext(iterator)))
	{
		OmLog(2, "DEVICE: Added...\n");

		// Store data relating to each device (service's name and location ID)
		DeviceData *deviceData = malloc(sizeof(DeviceData));
		if (deviceData == NULL)
		{
			OmLog(2, "MAC: Problem allocating device data\n");
			continue;
		}
		
		// A scope for better failure handling
		do {
			bzero(deviceData, sizeof(DeviceData));

			// Get the device name
			io_name_t deviceName = {0};
			kr = IORegistryEntryGetName(usbDevice, deviceName);
			if (KERN_SUCCESS != kr)
			{
				OmLog(2, "MAC: IORegistryEntryGetName returned 0x%08x\n", kr);
				break;
			}
			deviceData->deviceName = CFStringCreateWithCString(kCFAllocatorDefault, deviceName, kCFStringEncodingASCII);
			OmLog(3, "->deviceName: %s\n", deviceName);
			
			#if 1	// additional trace information about the device
			io_name_t className = {0};
			io_string_t pathName = {0};
			io_string_t pathName2 = {0};

			IOObjectGetClass(usbDevice, className);
			IORegistryEntryGetPath(usbDevice, kIOServicePlane, pathName);
			IORegistryEntryGetPath(usbDevice, kIOUSBPlane, pathName2);

			OmLog(3, "MAC: This device's className is %s\n", (const char*)className);
			OmLog(3, "MAC: Device's path in IOService plane = %s\n", pathName);
			OmLog(3, "MAC: Device's path in IOUSB plane = %s\n", pathName2);
			#endif

			// Create an IOUSBDeviceInterface to get the location ID (connection between application and USB device kernel object)
			kr = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugInInterface, &score);
			if ((kIOReturnSuccess != kr) || !plugInInterface)
			{
				OmLog(2, "MAC: IOCreatePlugInInterfaceForService returned 0x%08x\n", kr);
				break;
			}
			
			// Retrieve the device interface
			res = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID*) &deviceData->deviceInterface);
			
			// Release plugin interface
			(*plugInInterface)->Release(plugInInterface);
			if (res || deviceData->deviceInterface == NULL)
			{
				OmLog(2, "MAC: ERROR: QueryInterface returned %d.\n", (int) res);
				break;
			}
			
			// Routines from IOUSBLib.h can be called with the IOUSBDeviceInterface
			UInt32 locationID;
			kr = (*deviceData->deviceInterface)->GetLocationID(deviceData->deviceInterface, &locationID);
			if (KERN_SUCCESS != kr)
			{
				OmLog(2, "MAC: ERROR: GetLocationID returned 0x%08x.\n", kr);
				break;
			}
			deviceData->locationID = locationID;
			OmLog(3, "->locationID: 0x%lx.\n", deviceData->locationID);
			
			// printf("DEVICE: Find serial number...\n");
			deviceData->serialNumber = getUSBSerialNumber(usbDevice);
			if (deviceData->serialNumber == NULL || strlen(deviceData->serialNumber) == 0)
			{
				OmLog(2, "MAC: ERROR: Couldn't find USB serial number.\n");
				break;
			}
			OmLog(3, "->serialNumber: %s\n", deviceData->serialNumber);

			deviceData->deviceId = DeviceIdFromSerialNumber(deviceData->serialNumber);
			if (deviceData->deviceId == 0)
			{
				OmLog(2, "MAC: ERROR: Couldn't find device ID from USB serial number.\n");
				break;
			}
			OmLog(3, "->deviceId: %u\n", deviceData->deviceId);
			
			deviceData->mountPath = findMount(usbDevice);
			if (deviceData->mountPath == NULL || strlen(deviceData->mountPath) == 0)
			{
				OmLog(2, "MAC: ERROR: Couldn't find mount path.\n");
				break;
			}
			OmLog(3, "->mountPath: %s\n", deviceData->mountPath);
			
			deviceData->serialDevice = findSerial(deviceData->serialNumber);
			if (deviceData->serialDevice == NULL || strlen(deviceData->serialDevice) == 0)
			{
				OmLog(2, "MAC: ERROR: Couldn't find serial path.\n");
				break;
			}
			OmLog(3, "->serialDevice: %s\n", deviceData->serialDevice);

			// PATCH (omgui-mac) C6: arm the removal notification only now that every lookup has
			// succeeded.  Upstream registered it before the four steps above, each of which can
			// break out of this scope, and the bare free() below then left a live
			// kIOGeneralInterest notification holding a freed refCon: on the eventual unplug
			// DeviceNotification() read a dangling DeviceData and passed garbage pointers to
			// OmDeviceDiscovery(OM_DEVICE_REMOVED, ...).  findMount() gives up after ~8 s, so
			// this was reachable simply by attaching a device that is still re-mounting after a
			// FORMAT, or one waiting on "Allow accessory to connect".
			kr = IOServiceAddInterestNotification(gNotifyPort, usbDevice, kIOGeneralInterest, DeviceNotification, deviceData, &(deviceData->notification));
			if (KERN_SUCCESS != kr)
			{
				OmLog(2, "MAC: WARNING: IOServiceAddInterestNotification returned 0x%08x.\n", kr);
				break;
			}

			// PATCH (omgui-mac) L1: the record is now owned by the armed notification, so
			// register it before handing control to user code -- Stop() releases whatever is
			// still on this list when the notification port goes away.
			deviceData->next = gDeviceDataList;
			gDeviceDataList = deviceData;

			// Call device connected
			OmLog(2, "MAC: DEVICE: ... %s (#%u) port=%s path=%s\n", deviceData->serialNumber, deviceData->deviceId, deviceData->serialDevice, deviceData->mountPath);
			OmDeviceDiscovery(OM_DEVICE_CONNECTED, deviceData->deviceId, deviceData->serialNumber, deviceData->serialDevice, deviceData->mountPath);
			deviceData = NULL;	// clear reference to prevent freeing below
		} while (0);

		// We still have a reference if there was an issue
		if (deviceData) {
			OmLog(2, "MAC: ERROR: Overall problem determining device information.\n");
			fprintf(stderr, "ERROR: Overall problem determining device information. (Run with OMDEBUG=2 for details).\n");
			// PATCH (omgui-mac) C6/C36: explicit failure epilogue.  Upstream free()d the struct
			// and leaked everything it owned -- the interest notification (see above), the
			// deviceName CFString, the device interface, and the three heap strings.
			DeviceDataRelease(deviceData);
		}

		// Release IOIteratorNext reference
		kr = IOObjectRelease(usbDevice);
	}
}


static volatile int gStarted = 0;
static volatile int gFinished = 0;      // PATCH (omgui-mac) C17: set when the thread has returned
static volatile int gThreadValid = 0;   // PATCH (omgui-mac) C17: om.discoveryThread is joinable

// PATCH (omgui-mac) M1: statically initialised, and never re-initialised or destroyed.  C17
// re-ran pthread_mutex_init()/pthread_cond_init() on these same statics at the top of every
// OmDeviceDiscoveryStart(), which is undefined behaviour on a mutex that is already initialised
// and, after an H4 detach, on one an orphaned thread is still locking from OmDiscoverySignal().
static pthread_mutex_t gStartMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gStartCond = PTHREAD_COND_INITIALIZER;

/** PATCH (omgui-mac) C17: publish a discovery-thread lifecycle change. */
static void OmDiscoverySignal(int started, int finished)
{
	pthread_mutex_lock(&gStartMutex);
	if (started) { gStarted = 1; }
	if (finished) { gFinished = 1; }
	pthread_cond_broadcast(&gStartCond);
	pthread_mutex_unlock(&gStartMutex);
}

static thread_return_t OmDeviceDiscoveryThread(void *arg)
{
	// PATCH (omgui-mac): upstream installed a SIGINT handler here that called exit(0).
	// A library must not take over the host application's Ctrl-C, and must never exit the
	// process on its behalf, so no handler is installed.

	// PATCH (omgui-mac): upstream chose "IOUSBDevice" vs "IOUSBHostDevice" from a runtime OS
	// version computed as (darwinMajor - 9), which stopped mapping to the marketing version at
	// macOS 26 (Darwin 25).  This build targets macOS 14+, where the class is always
	// "IOUSBHostDevice", so the version probe (and osVersion()) has been removed.
	const char *serviceMatcher = "IOUSBHostDevice";
	OmLog(2, "MAC: NOTE: serviceMatcher=%s\n", serviceMatcher);

	CFMutableDictionaryRef matchingDict = IOServiceMatching(serviceMatcher);		// kIOUSBDeviceClassName="IOUSBDevice"
	if (matchingDict == NULL)
	{
		OmLog(2, "ERROR: IOServiceMatching returned NULL.\n");
		fprintf(stderr, "ERROR: IOServiceMatching returned NULL.\n");
		OmDiscoverySignal(1, 1);	// PATCH (omgui-mac) C17: never leave OmDeviceDiscoveryStart() waiting
		return thread_return_value(1);
	}
	
	// Register interest in all USB devices that match the vid/pid
	{
		long usbVendor = VID;
		long usbProduct = PID;
		CFNumberRef numberRef;
		
		OmLog(3, "DEVICE: Looking for USB class instances VID=%04x PID=%04x...\n", (int)usbVendor, (int)usbProduct);
		
		// ...vendor id
		numberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usbVendor);
		CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), numberRef);
		CFRelease(numberRef);
		
		// ...product id
		numberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usbProduct);
		CFDictionarySetValue(matchingDict, CFSTR(kUSBProductID), numberRef);
		CFRelease(numberRef);
	}

	// Set up async notifications using a notification port and its run loop event source
	gNotifyPort = IONotificationPortCreate(kIOMainPortDefault);		// PATCH (omgui-mac): kIOMasterPortDefault deprecated in macOS 12
	CFRunLoopSourceRef runLoopSource = IONotificationPortGetRunLoopSource(gNotifyPort);
	
	gRunLoop = CFRunLoopGetCurrent();
	CFRunLoopAddSource(gRunLoop, runLoopSource, kCFRunLoopDefaultMode);
	
	// Notification when a device is matched by I/O Kit
	kern_return_t kr = IOServiceAddMatchingNotification(gNotifyPort, kIOFirstMatchNotification,	matchingDict, DeviceAdded, NULL, &gAddedIter);
	if (KERN_SUCCESS != kr)
	{
		OmLog(2, "WARNING: IOServiceAddMatchingNotification failed\n");
		fprintf(stderr, "WARNING: IOServiceAddMatchingNotification failed\n");
	}
	
	// Iterate once to get already-present devices and arm the notification	
	DeviceAdded(NULL, gAddedIter);	

	// PATCH (omgui-mac) C17: signal from inside the run loop rather than before it.  Upstream
	// signalled here and papered over the gap with a 200 ms usleep() in OmDeviceDiscoveryStart();
	// a quit inside that window (which --self-test reaches by construction) issued its
	// CFRunLoopStop() before CFRunLoopRun() and then blocked forever in an unbounded join.
	CFRunLoopPerformBlock(gRunLoop, kCFRunLoopDefaultMode, ^{
		OmLog(3, "DEVICE: Run loop running.\n");
		OmDiscoverySignal(1, 0);
	});
	CFRunLoopWakeUp(gRunLoop);

	// while (!om.quitDiscoveryThread)
	// Start the run loop, we will receive notifications
	OmLog(3, "DEVICE: Starting run loop...\n");
	CFRunLoopRun();
	
	OmLog(3, "DEVICE: Run loop returned\n");
	OmDiscoverySignal(1, 1);
    return thread_return_value(0);
}



/** Internal method to start device discovery. */
void OmDeviceDiscoveryStart(void)
{
	// PATCH (omgui-mac) M1/H4: an orphaned discovery thread from a previous cycle still owns the
	// notify port and still signals gStarted/gFinished, which are single global slots.  Starting a
	// second thread over them makes the new Start() return before its run loop is up and the next
	// Stop() skip every CFRunLoopStop() and then join a running loop -- a permanent hang, i.e. the
	// exact bug C17 exists to remove.  Discovery is refused instead: the app keeps working with
	// whatever it has, rather than deadlocking on quit.
	if (gDiscoveryDetached)
	{
		OmLog(0, "WARNING: Device discovery was orphaned by an earlier stop; not restarting it.\n");
		return;
	}

    om.quitDiscoveryThread = 0;

	// Initialize (the mutex and condition variable are statically initialised -- see M1 above)
    pthread_mutex_lock(&gStartMutex);
	gStarted = 0;
	gFinished = 0;

    //OmUpdateDevices();
    if (thread_create(&om.discoveryThread, NULL, OmDeviceDiscoveryThread, NULL) != 0)
    {
        pthread_mutex_unlock(&gStartMutex);
        OmLog(0, "ERROR: Could not create the device discovery thread.\n");
        return;
    }
    gThreadValid = 1;

	// Wait for the thread to report that its run loop is running (or that it gave up)
    while (!gStarted && !gFinished)
	{
		OmLog(3, "DEVICE: Waiting...%d\n", gStarted);
        pthread_cond_wait(&gStartCond, &gStartMutex);
	}
    pthread_mutex_unlock(&gStartMutex);	

	// PATCH (omgui-mac) C17: the 200 ms "ensure the run loop really starts" usleep() is gone --
	// the signal now comes from a block running inside the loop, so it is already running here.

	OmLog(3, "DEVICE: Started...\n");
}

/** Internal method to stop device discovery. */
void OmDeviceDiscoveryStop(void)
{
	int attempt;
	int finished;

    om.quitDiscoveryThread = 1;
	if (!gThreadValid) { return; }		// Never started, or already stopped

	OmLog(3, "DEVICE: Stopping run loop...\n");
	// PATCH (omgui-mac): upstream called CFRunLoopStop() then immediately pthread_cancel(), which
	// can tear the thread down inside CoreFoundation.  findMount() now polls quitDiscoveryThread,
	// so the thread returns on its own and we join it.
	//
	// PATCH (omgui-mac) C17: the join is no longer unbounded.  A single CFRunLoopStop() can be
	// lost (the loop may not have entered yet, and CFRunLoopRun() can re-enter for a queued
	// source), which turned Cmd-Q into a permanent hang; retry the stop for up to ~5 s and join
	// only once the thread has actually reported that it returned.
	pthread_mutex_lock(&gStartMutex);
	for (attempt = 0; attempt < 100 && !gFinished; attempt++)
	{
		struct timespec ts;
		struct timeval now;

		pthread_mutex_unlock(&gStartMutex);
		if (gRunLoop != NULL) { CFRunLoopStop(gRunLoop); }
		pthread_mutex_lock(&gStartMutex);
		if (gFinished) { break; }

		gettimeofday(&now, NULL);
		ts.tv_sec = now.tv_sec;
		ts.tv_nsec = (long)(now.tv_usec + 50 * 1000) * 1000;
		while (ts.tv_nsec >= 1000000000L) { ts.tv_nsec -= 1000000000L; ts.tv_sec++; }
		pthread_cond_timedwait(&gStartCond, &gStartMutex, &ts);
	}
	finished = gFinished;
	pthread_mutex_unlock(&gStartMutex);

	gThreadValid = 0;
	if (!finished)
	{
		// PATCH (omgui-mac) H4/L1: a bounded quit beats a correct one, but C17's bare
		// pthread_detach() traded the hang for undefined behaviour -- it left the callbacks armed
		// and told OmShutdown() nothing, so the frees and both mutex_destroy()s ran while a thread
		// stuck in getUSBStringDescriptor()'s DeviceRequest or in DiskArbitration was still walking
		// the device table, locking om.downloadMutex and calling om.deviceCallback (which resolves
		// an Unmanaged<LibOmapiBackend> the caller is about to release).
		//
		// So: cut every route from the orphan back into the caller *before* detaching it, tell
		// OmShutdown() to free nothing and destroy nothing (OmDeviceDiscoveryDetached), and leave
		// the orphan owning gNotifyPort, gAddedIter and every registered DeviceData -- it is still
		// using all three, and destroying the port under it is exactly the crash we are avoiding.
		// Only gRunLoop is cleared, so a later CFRunLoopStop() cannot target a stale reference.
		OmLog(0, "WARNING: Device discovery thread did not stop; detaching it.\n");

		om.deviceCallback = NULL;
		om.deviceCallbackReference = NULL;
		om.downloadCallback = NULL;
		om.downloadCallbackReference = NULL;
		om.downloadChunkCallback = NULL;
		om.downloadChunkCallbackReference = NULL;
		// OmLog() itself calls out through this one, from findMount() among others; the message
		// above is deliberately emitted before it is cleared.
		om.logCallback = NULL;
		om.logCallbackReference = NULL;

		gRunLoop = NULL;
		gDiscoveryDetached = 1;
		pthread_detach(om.discoveryThread);
		return;
	}

	thread_join(om.discoveryThread, NULL);

	// PATCH (omgui-mac) L1: the thread is joined, so nothing else can be in DeviceAdded() or
	// DeviceNotification() and the registry can be walked unlocked.  Each armed
	// kIOGeneralInterest notification owns its DeviceData, and destroying the port below means
	// DeviceNotification() can never fire again -- so release them here, running the same
	// epilogue that callback would have run.  No OM_DEVICE_REMOVED is issued: the devices are
	// still attached, and a restart's DeviceAdded() will report them again.
	while (gDeviceDataList != NULL)
	{
		DeviceData *deviceData = gDeviceDataList;
		gDeviceDataList = deviceData->next;
		deviceData->next = NULL;
		DeviceDataRelease(deviceData);
	}

	// PATCH (omgui-mac) C17: upstream released neither, so every stop/start cycle leaked a mach
	// port and left a second matching notification armed on the same iterator.
	if (gAddedIter) { IOObjectRelease(gAddedIter); gAddedIter = 0; }
	if (gNotifyPort != NULL) { IONotificationPortDestroy(gNotifyPort); gNotifyPort = NULL; }
	gRunLoop = NULL;
}

#endif  // __APPLE__
