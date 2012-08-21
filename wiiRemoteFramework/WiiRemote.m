//
//  WiiRemote.m
//  DarwiinRemote
//
//  Created by KIMURA Hiroaki on 06/12/04.
//  Copyright 2006 KIMURA Hiroaki. All rights reserved.
//

#import "WiiRemote.h"
#include <unistd.h>

static void NSLogDebugBlock(NSString *prompt, unsigned dataLength, unsigned char *dp) {
#if DEBUG
	printf ("\n%s %3d:\n", [prompt UTF8String], dataLength);
	int i;
	for(i=0 ; i < dataLength ; i++) {
		printf(" %02X", dp[i]);
		if (i && 0 == (i%40)) {
			printf("\n");
		}
	}
#endif
}

static WiiJoyStickCalibData kWiiNullJoystickCalibData = {0, 0, 0, 0, 0, 0};
static WiiAccCalibData kWiiNullAccCalibData = {0, 0, 0, 0, 0, 0};
static WiiBalanceBeamCalibData kWiiNullBalanceBeamCalibData = {
	{0, 0, 0, 0}
};

// define some constants
#define kWiiIRPixelsWidth 1024.0
#define kWiiIRPixelsHeight 768.0

#define WII_DECRYPT(data) (((data ^ 0x17) + 0x17) & 0xFF)

#define WIR_HALFRANGE 256.0
#define WIR_INTERVAL  10.0

// Notification strings
NSString * WiiRemoteExpansionPortChangedNotification = @"WiiRemoteExpansionPortChangedNotification";


// this type is used a lot (data array):
typedef unsigned char darr[];


typedef enum {
	kWiiRemoteTwoButton					= 0x0001,
	kWiiRemoteOneButton					= 0x0002,
	kWiiRemoteBButton					= 0x0004,
	kWiiRemoteAButton					= 0x0008,
	kWiiRemoteMinusButton				= 0x0010,
	kWiiRemoteHomeButton				= 0x0080,
	kWiiRemoteLeftButton				= 0x0100,
	kWiiRemoteRightButton				= 0x0200,
	kWiiRemoteDownButton				= 0x0400,
	kWiiRemoteUpButton					= 0x0800,
	kWiiRemotePlusButton				= 0x1000,

	kWiiNunchukZButton					= 0x0001,
	kWiiNunchukCButton					= 0x0002,

	kWiiClassicControllerUpButton		= 0x0001,
	kWiiClassicControllerLeftButton		= 0x0002,
	kWiiClassicControllerZRButton		= 0x0004,
	kWiiClassicControllerXButton		= 0x0008,
	kWiiClassicControllerAButton		= 0x0010,
	kWiiClassicControllerYButton		= 0x0020,
	kWiiClassicControllerBButton		= 0x0040,
	kWiiClassicControllerZLButton		= 0x0080,
	kWiiClassicControllerUnUsedButton	= 0x0100,
	kWiiClassicControllerRButton		= 0x0200,
	kWiiClassicControllerPlusButton		= 0x0400,
	kWiiClassicControllerHomeButton		= 0x0800,
	kWiiClassicControllerMinusButton	= 0x1000,
	kWiiClassicControllerLButton		= 0x2000,
	kWiiClassicControllerDownButton		= 0x4000,
	kWiiClassicControllerRightButton	= 0x8000
	
} WiiButtonBitMask;

#pragma mark -
#pragma mark ** BalanceBeam Helpers **

// Each of the 4 Corners should be increasing.
static BOOL AreQuadsValid(WiiQuad *quads) {
	return quads[0].topRight < quads[1].topRight && quads[1].topRight < quads[2].topRight &&
	quads[0].bottomRight < quads[1].bottomRight && quads[1].bottomRight < quads[2].bottomRight &&
	quads[0].topLeft < quads[1].topLeft && quads[1].topLeft < quads[2].topLeft &&
	quads[0].bottomLeft < quads[1].bottomLeft && quads[1].bottomLeft < quads[2].bottomLeft;	
}

// valLow corresponds to calibratedLow
// valHigh corresponds to calibratedHigh
// given valRaw, linearly interpolate and return the appropriate calibrated value.
float BBInterpolate2(unsigned short valRaw, unsigned short valLow, unsigned short valHigh, float low, float high){
	return low + (((int)valRaw - (int)valLow) * (high-low) / ((float)valHigh - valLow));
}

float BBInterpolate(unsigned short valRaw, unsigned short val0, unsigned short val17, unsigned short val34) {
	if (valRaw < val17) {
		return BBInterpolate2(valRaw, val0, val17, 0.0f, 17.0f);
	} else {
		return BBInterpolate2(valRaw, val17, val34, 17.0f, 34.0f);
	}
}

#pragma mark -


@interface WiiRemote (Private)
- (IOBluetoothL2CAPChannel *) openL2CAPChannelWithPSM:(BluetoothL2CAPPSM) psm delegate:(id) delegate;
@end

@implementation WiiRemote

- (id) init
{
	self = [super init];
	
	NSLogDebug (@"Wii instantiated");

	if (self != nil) {
		accX = 0x10;
		accY = 0x10;
		accZ = 0x10;
		buttonData = 0;
		leftPoint = -1;
		_batteryLevel = 0;
		_warningBatteryLevel = 0.05;

		_delegate = nil;
		_shouldUpdateReportMode = NO;
		_shouldReadExpansionCalibration = NO;
		_wiiDevice = nil;
		
		_opened = NO;
	
		_ichan = nil;
		_cchan = nil;
		
		_isIRSensorEnabled = NO;
		_isMotionSensorEnabled = NO;
		_isVibrationEnabled = NO;
		_isExpansionPortEnabled = NO;
		_isExpansionPortAttached = NO;
		
		wiiIRMode = kWiiIRModeExtended;
		expType = WiiExpNotAttached;
		balanceBeamCalibData = kWiiNullBalanceBeamCalibData;
	}
	return self;
}

- (void) dealloc
{
	NSLogDebug (@"Wii released");
	[super dealloc];
}

- (void) setDelegate:(id<WiiRemoteDelegate>) delegate
{
	_delegate = delegate;
}

- (BOOL) available
{
	if ((_wiiDevice != nil) && (_cchan != nil) && (_ichan != nil))
		return YES;
	
	return NO;
}

- (IOReturn) connectTo:(IOBluetoothDevice *) device
{ 
	_wiiDevice = device; 
	if (_wiiDevice == nil)
		return kIOReturnBadArgument; 

	IOReturn ret = kIOReturnSuccess;

	// it seems like it is not needed to call openConnection in order to open L2CAP channels ...
	_cchan = [self openL2CAPChannelWithPSM:kBluetoothL2CAPPSMHIDControl delegate:self];
	if (!_cchan)
		return kIOReturnNotOpen;

	usleep(20000);
	_ichan = [self openL2CAPChannelWithPSM:kBluetoothL2CAPPSMHIDInterrupt delegate:self];
	if (!_ichan)
		return kIOReturnNotOpen;
	
	usleep(20000);
	
//            statusTimer = [[NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(getCurrentStatus:) userInfo:nil repeats:YES] retain];
	// TODO: this is a kludge. We should be looking for the device ID.
	// full name is @"Nintendo RVL-WBC-01"
	_isBalanceBeam = [[_wiiDevice getName] hasPrefix:@"Nintendo RVL-WBC"];
	ret = [self getCurrentStatus:nil];	

	if (ret == kIOReturnSuccess && ! _isBalanceBeam) {
		// Get Accelerometer calibration data
		ret = [self readData:0x0020 length:7];
	}
	if (ret == kIOReturnSuccess) {
		[self setMotionSensorEnabled:NO];
		[self setIRSensorEnabled:NO];
		[self setForceFeedbackEnabled:NO];
		[self setLEDEnabled1:NO enabled2:NO enabled3:NO enabled4:NO];
		[self updateReportMode];
//		ret = [self doUpdateReportMode];
	}
	
	if ((ret == kIOReturnSuccess) && [self available]) {
		disconnectNotification = [_wiiDevice registerForDisconnectNotification:self selector:@selector(disconnected:fromDevice:)];
		_opened = YES;
	} else {
		_opened = NO;
		[self closeConnection];
	}
	NSLogDebug(@"connectTo returns:%d", ret);
	return ret;
}

- (void) disconnected:(IOBluetoothUserNotification*) note fromDevice:(IOBluetoothDevice*) device
{
	NSLogDebug (@"Disconnected.");
	if (device == _wiiDevice) {
//		_cchan = nil;
//		_ichan = nil;
		[self closeConnection];
	}
}

- (IOReturn) sendCommand:(const unsigned char *) data length:(size_t) length
{		
	unsigned char buf[40];
	memset (buf, 0, 40);

	buf[0] = 0x52;
	memcpy (buf+1, data, length);
	if (buf[1] == 0x16) length = 23;
	else				length++;

//	printf ("send%3d:", length);
//	for(i=0 ; i<length ; i++) {
//		printf(" %02X", buf[i]);
//	}
//	printf("\n");
	NSLogDebugBlock(@"send:", length, buf);
	
	IOReturn ret = kIOReturnSuccess;
	
	// cam: i think there is no need to do the loop many times in order to see there is an error
	// if there's an error it must be managed right away
	int i;
	for (i=0; i<6 ; i++) {
		ret = [_cchan writeSync:buf length:length];		
		if (ret != kIOReturnSuccess) {
			NSLogDebug(@"Write Error for command 0x%x:", buf[1], ret);		
			LogIOReturn (ret);
//			[self closeConnection];
			usleep (10000);
		}
		else
			break;
	}

	return ret;
}

- (double) batteryLevel
{
	return _batteryLevel;
}

- (NSString *) address
{
	return [_wiiDevice getAddressString];
}

- (void) setMotionSensorEnabled:(BOOL) enabled
{
	if (_isBalanceBeam) {
		return;
	}
	if (enabled) {
		NSLogDebug (@"Set motion sensor enabled");
	} else {
		NSLogDebug (@"Set motion sensor disabled");
	}

	// this variable indicate a desire, and should be updated regardless of the sucess of sending the command
	_isMotionSensorEnabled = enabled;	

	[self updateReportMode];
}


- (void) setForceFeedbackEnabled:(BOOL) enabled
{
	if (_isBalanceBeam) {
		return;
	}
	// this variable indicate a desire, and should be updated regardless of the sucess of sending the command
	_isVibrationEnabled = enabled;
	[self updateReportMode];
}

- (void) setLEDEnabled1:(BOOL) enabled1 enabled2:(BOOL) enabled2 enabled3:(BOOL) enabled3 enabled4:(BOOL) enabled4
{
	if (_isBalanceBeam) {
		return;
	}
	unsigned char cmd[] = {0x11, 0x00};
	if (_isVibrationEnabled)	cmd[1] |= 0x01;
	if (enabled1)	cmd[1] |= 0x10;
	if (enabled2)	cmd[1] |= 0x20;
	if (enabled3)	cmd[1] |= 0x40;
	if (enabled4)	cmd[1] |= 0x80;
	
	_isLED1Illuminated = enabled1;
	_isLED2Illuminated = enabled2;
	_isLED3Illuminated = enabled3;
	_isLED4Illuminated = enabled4;
	
	IOReturn ret = [self sendCommand:cmd length:2];
  if (ret) {}  // otherwise release target will complain: unused.
	LogIOReturn (ret);
}

- (void) updateReportMode
{
	_shouldUpdateReportMode = YES;
	
	if (!_cchan)
		[self closeConnection];
}

- (IOReturn) doUpdateReportMode
{
	if (!_shouldUpdateReportMode)
		return kIOReturnSuccess;

	_shouldUpdateReportMode = NO;

	NSLogDebug (@"Updating Report Mode");
	// Set the report type the Wiimote should send.
	unsigned char cmd[] = {0x12, 0x02, 0x30}; // Just buttons.
	
	/*
		There are numerous status report types that can be requested.
		The IR reports must be matched with the data format set when initializing the IR camera:
			0x36, 0x37	- 10 IR bytes go with Basic mode
			0x33		- 12 IR bytes go with Extended mode
			0x3e/0x3f	- 36 IR bytes go with Full mode
		
		The Nunchuk and Classic controller use 6 bytes to report their state, so the reports that
		give more extension bytes don't provide any more info.
		
				Buttons		|	Accelerometer	|	IR		|	Extension
		--------------------+-------------------+-----------+-------------		
		0x30: Core Buttons	|					|			|
		0x31: Core Buttons	|	Accelerometer	|			|
		0x32: Core Buttons	|					|			|	 8 bytes
		0x33: Core Buttons	|	Accelerometer	| 12 bytes	|
		0x34: Core Buttons	|					|			|	19 bytes
		0x35: Core Buttons	|	Accelerometer	|			|	16 bytes
		0x36: Core Buttons	|					| 10 bytes	|	 9 bytes
		0x37: Core Buttons	|	Accelerometer	| 10 bytes	|	 6 bytes
		?? 0x38: Core Buttons and Accelerometer with 16 IR bytes ??
		0x3d:				|					|			|	21 bytes
		
		0x3e / 0x3f: Interleaved Core Buttons and Accelerometer with 16/36 IR bytes
		
	*/
	if (_isIRSensorEnabled) {
		cmd[2] = _isExpansionPortEnabled ? 0x36 : 0x33;	// Buttons, 10 IR Bytes, 9 Extension Bytes
		wiiIRMode = _isExpansionPortEnabled ? kWiiIRModeBasic : kWiiIRModeExtended;
		
		// Set IR Mode
		//		NSLogDebug (@"Setting IR Mode to finish initialization.");
		// I don't think it should be here ...		
		[self writeData:(darr){ wiiIRMode } at:0x04B00033 length:1];
		usleep(10000);
	} else {
		cmd[2] = _isExpansionPortEnabled ? 0x34 : 0x30;	// Buttons, 19 Extension Bytes	 
	}
	
	if (_isVibrationEnabled)
		cmd[1] |= 0x01;

	if (_isMotionSensorEnabled)
		cmd[2] |= 0x01;	// Add Accelerometer
	
	usleep(10000);
	return [self sendCommand:cmd length:3];

} // updateReportMode

- (void) setExpansionPortEnabled:(BOOL) enabled
{	
	IOReturn ret = kIOReturnSuccess;
	
	if (enabled)
		NSLogDebug (@"Enabling expansion port.");
	else
		NSLogDebug (@"Disabling expansion port.");	

	if (_isExpansionPortAttached) {
		_isExpansionPortEnabled = enabled;
		// get expansion device calibration data
		_shouldReadExpansionCalibration = YES;
		_shouldReadExpansionCalibrationHigh = YES;
		if (_isBalanceBeam) {
			// report format doesn't allow us to get the entire calibration
			// data in single read.
      usleep(10000);
			ret = [self readData:0x04a40024 length: 12];
			if (ret == kIOReturnSuccess) {
				usleep(10000);
				ret = [self readData:0x04a40030 length: 12];
			}
		} else {
			ret = [self readData:0x04A40020 length: 16];
		}
		LogIOReturn (ret);
	}

	[self updateReportMode];
}

//based on Ian's codes. thanks!
- (void) setIRSensorEnabled:(BOOL) enabled
{
	if (_isBalanceBeam) {
		return;
	}
	_isIRSensorEnabled = enabled;
		
	// ir enable 1
	IOReturn ret = kIOReturnSuccess;
	unsigned char cmd[] = {0x13, 0x00};
	if (_isVibrationEnabled) cmd[1] |= 0x01;
	if (_isIRSensorEnabled)  cmd[1] |= 0x04;
	ret = [self sendCommand:cmd length:2];
	LogIOReturn (ret);
	usleep(10000);
	
	// set register 0x1a (ir enable 2)
	unsigned char cmd2[] = {0x1a, 0x00};
	if (_isIRSensorEnabled)	cmd2[1] |= 0x04;
	ret = [self sendCommand:cmd2 length:2];
	LogIOReturn (ret);
	usleep(10000);

	if (_isIRSensorEnabled) {
		NSLogDebug (@"Enabling IR Sensor");
		
		// based on marcan's method, found on wiili wiki:
		// tweaked to include some aspects of cliff's setup procedure in the hopes
		// of it actually turning on 100% of the time (was seeing 30-40% failure rate before)
		// the sleeps help it it seems

		// start initializing camera
		ret = [self writeData:(darr){0x01} at:0x04B00030 length:1];
		LogIOReturn (ret);
		usleep(10000);
		
		// set sensitivity block 1
		ret = [self writeData:(darr){0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x90, 0x00, 0xC0} at:0x04B00000 length:9];
		LogIOReturn (ret);
		usleep(10000);
		
		// set sensitivity block 2
		ret = [self writeData:(darr){0x40, 0x00} at:0x04B0001A length:2];
		LogIOReturn (ret);
		usleep(10000);
				
		// finish initializing camera
		ret = [self writeData:(darr){0x08} at:0x04B00030 length:1];
		LogIOReturn (ret);
		usleep(10000);
		
		if (ret != kIOReturnSuccess) {
			NSLogDebug (@"Set IR Enabled failed, closing connection");
//			[self closeConnection];
			_isIRSensorEnabled = NO;
			return;
		}
	}
	
	[self updateReportMode];
}


- (IOReturn) writeData:(const unsigned char*) data at:(unsigned long) address length:(size_t) length
{
	unsigned char cmd [22];

	if (length > 16)
		NSLog (@"Error! Trying to write more than 16 bytes of data (length=%i)", length);

	memset (cmd, 0, 22);
	memcpy (cmd + 6, data, length);

	// register write header
	cmd[0] = 0x16;

	// write address
	cmd[1] = (address >> 24) & 0xFF;
	cmd[2] = (address >> 16) & 0xFF;
	cmd[3] = (address >>  8) & 0xFF;
	cmd[4] = (address >>  0) & 0xFF;
	
	// data length
	cmd[5] = length;
	
	// and of course the vibration flag, as usual
	if (_isVibrationEnabled)
		cmd[1] |= 0x01;

	return [self sendCommand:cmd length:22];
}


- (IOReturn) readData:(unsigned long) address length:(unsigned short) length
{	
	unsigned char cmd[7];
	unsigned long addr = address;
	unsigned short len = length;
	
	cmd[0] = 0x17; // read memory
	
	// address
	cmd[1] = (addr >> 24) & 0xFF;  // bit 2 being set indicates read from control registers, 0 indicates EEPROM Memory
	cmd[2] = (addr >> 16) & 0xFF;
	cmd[3] = (addr >>  8) & 0xFF;
	cmd[4] = (addr >>  0) & 0xFF;
	
	// Number of bytes to read
	cmd[5] = (len >> 8) & 0xFF;
	cmd[6] = (len >> 0) & 0xFF;
	
	if (_isVibrationEnabled)
		cmd[1] |= 0x01;

	return [self sendCommand:cmd length:7];
}

- (IOReturn) closeConnection
{
	IOReturn ret = 0;
	_opened = NO;

	[disconnectNotification unregister];
	disconnectNotification = nil;

	[_delegate wiiRemoteDisconnected:_wiiDevice];
	_delegate = nil;

	// cam: set delegate to nil
	[_cchan setDelegate:nil];
	ret = [_cchan closeChannel];
    [_cchan release];
	_cchan = nil;
	LogIOReturn (ret);
	
	[_ichan setDelegate:nil];
	ret = [_ichan closeChannel];
    [_ichan release];
	_ichan = nil;
	LogIOReturn (ret);

	ret = [_wiiDevice closeConnection];
	_wiiDevice = nil;
	LogIOReturn (ret);

	// no longer a delegate
	[statusTimer invalidate];
	[statusTimer release];
	statusTimer = nil;
	
	return ret;
}

- (void) handleWriteResponse:(unsigned char *) dp length:(size_t) dataLength
{
	NSLogDebug (@"Write data response: %00x %00x %00x %00x", dp[2], dp[3], dp[4], dp[5]);
}


	/**
	 * Handle report 0x21 (Read Data) from wiimote.
	 * dp[0] = Bluetooth header
	 * dp[1] = (0x21) Report/Channel ID
	 * dp[2] = Wiimote Buttons
	 * dp[3] = Wiimote Buttons
	 * dp[4] = High 4 bits = payload size; Low 4 bits = Error flag (0 = all good)	 
	 * dp[5] = Offset of memory read
	 * dp[6] = Offset of memory read
	 * dp[7+] = the Data.
	 **/
- (void) handleRAMData:(unsigned char *) dp length:(size_t) dataLength
{
	/**
	if (dp[1] == 0x21){
		int i;
		
		printf ("ack%3d:", dataLength);
		for(i=0 ; i<dataLength ; i++) {
			printf(" %02X", dp[i]);
		}
		printf("\n");
	}**/

	unsigned short addr = (dp[5] * 256) + dp[6];
	NSLogDebug (@"handleRAMData (0x21) addr=0x%x", addr);
	
	//mii data
	if ((dataLength >= 20) && (addr >= WIIMOTE_MII_DATA_BEGIN_ADDR) && (addr <= WIIMOTE_MII_CHECKSUM1_ADDR)) { 
		if ([_delegate respondsToSelector:@selector (gotMiidata:at:)]) {
			int slot = MII_SLOT(addr);
			int len = dataLength - 7;
			memcpy (&mii_data_buf[mii_data_offset], &dp[7], len);
			mii_data_offset += len;
			if (mii_data_offset >= WIIMOTE_MII_DATA_BYTES_PER_SLOT)
				[_delegate gotMiiData: (Mii *)mii_data_buf at: slot];
		}		
	}

	// specify attached expasion device
	if (addr == 0x00F0) {
		NSLogDebug (@"Expansion device connected.");
		
		switch (WII_DECRYPT(dp[21])) {
			case 0x00:
				NSLogDebug (@"Nunchuk connected.");
				if (expType != WiiNunchuk) {
					expType = WiiNunchuk;
					[[NSNotificationCenter defaultCenter] postNotificationName:WiiRemoteExpansionPortChangedNotification object:self];
				}
				break;
			case 0x01:
				NSLogDebug (@"Classic controller connected.");
				if (expType != WiiClassicController) {
					expType = WiiClassicController;
					[[NSNotificationCenter defaultCenter] postNotificationName:WiiRemoteExpansionPortChangedNotification object:self];				
				}
				break;
			case 0x2A:
				NSLogDebug (@"Balance Beam connected.");
				if (expType != WiiBalanceBeam) {
					expType = WiiBalanceBeam;
					[[NSNotificationCenter defaultCenter] postNotificationName:WiiRemoteExpansionPortChangedNotification object:self];				
				}
				break;
			default:
				NSLogDebug (@"Unknown device connected (0x%x). ", WII_DECRYPT(dp[21]));
				expType = WiiExpNotAttached;
				break;
		}

		return;
	}
		
	// wiimote calibration data
	if (!_shouldReadExpansionCalibration && (addr == 0x0020)) {
		NSLogDebug (@"Read Wii calibration");
		wiiCalibData.accX_zero = dp[7] << 1;
		wiiCalibData.accY_zero = dp[8] << 1;
		wiiCalibData.accZ_zero = dp[9] << 1;
		//dp[10] - unknown/unused
		wiiCalibData.accX_1g = dp[11] << 1;
		wiiCalibData.accY_1g = dp[12] << 1;
		wiiCalibData.accZ_1g = dp[13] << 1;
		return;
	}
	
	// expansion device calibration data.
	if (_shouldReadExpansionCalibrationHigh &&expType == WiiBalanceBeam && addr == 0x0030) {
		balanceBeamCalibData.quad[1].topLeft = ((unsigned short) dp[7] << 8) | dp[8];
		balanceBeamCalibData.quad[1].bottomLeft = ((unsigned short) dp[9] << 8) | dp[10];
		balanceBeamCalibData.quad[2].topRight = ((unsigned short) dp[11] << 8) | dp[12];
		balanceBeamCalibData.quad[2].bottomRight = ((unsigned short) dp[13] << 8) | dp[14];
		balanceBeamCalibData.quad[2].topLeft = ((unsigned short) dp[15] << 8) | dp[16];
		balanceBeamCalibData.quad[2].bottomLeft = ((unsigned short) dp[17] << 8) | dp[18];
		NSLogDebug(@"{%d %d %d %d} {%d %d %d %d} {%d %d %d %d}", 
			balanceBeamCalibData.quad[0].topRight, 
			balanceBeamCalibData.quad[0].bottomRight, 
			balanceBeamCalibData.quad[0].topLeft, 
			balanceBeamCalibData.quad[0].bottomLeft,

			balanceBeamCalibData.quad[1].topRight, 
			balanceBeamCalibData.quad[1].bottomRight, 
			balanceBeamCalibData.quad[1].topLeft, 
			balanceBeamCalibData.quad[1].bottomLeft,

			balanceBeamCalibData.quad[2].topRight, 
			balanceBeamCalibData.quad[2].bottomRight, 
			balanceBeamCalibData.quad[2].topLeft, 
			balanceBeamCalibData.quad[2].bottomLeft);
		_shouldReadExpansionCalibrationHigh = NO;
		if (!_shouldReadExpansionCalibration && !_shouldReadExpansionCalibrationHigh) {
			balanceBeamCalibData.isInitialized = AreQuadsValid(balanceBeamCalibData.quad);
		}
		return;
	}
	if (_shouldReadExpansionCalibration) {
		if (expType == WiiBalanceBeam && addr == 0x0024) {
			NSLogDebugBlock(@"calib", dataLength, dp);
			balanceBeamCalibData.quad[0].topRight = ((unsigned short) dp[7] << 8) | dp[8];
			balanceBeamCalibData.quad[0].bottomRight = ((unsigned short) dp[9] << 8) | dp[10];
			balanceBeamCalibData.quad[0].topLeft = ((unsigned short) dp[11] << 8) | dp[12];
			balanceBeamCalibData.quad[0].bottomLeft = ((unsigned short) dp[13] << 8) | dp[14];
			balanceBeamCalibData.quad[1].topRight = ((unsigned short) dp[15] << 8) | dp[16];
			balanceBeamCalibData.quad[1].bottomRight = ((unsigned short) dp[17] << 8) | dp[18];
			NSLogDebug(@"{%d %d %d %d}", 
					   balanceBeamCalibData.quad[0].topRight, 
					   balanceBeamCalibData.quad[0].bottomRight, 
					   balanceBeamCalibData.quad[0].topLeft, 
					   balanceBeamCalibData.quad[0].bottomLeft);
			_shouldReadExpansionCalibration = NO;
			if (!_shouldReadExpansionCalibration && !_shouldReadExpansionCalibrationHigh) {
				balanceBeamCalibData.isInitialized = AreQuadsValid(balanceBeamCalibData.quad);
			}
			return;
		} else if (addr == 0x0020) {
			if (expType == WiiNunchuk) {
				NSLogDebug (@"Read nunchuk calibration");
				//nunchuk calibration data
				nunchukCalibData.accX_zero =  WII_DECRYPT(dp[7]);
				nunchukCalibData.accY_zero =  WII_DECRYPT(dp[8]);
				nunchukCalibData.accZ_zero =  WII_DECRYPT(dp[9]);
				
				nunchukCalibData.accX_1g =  WII_DECRYPT(dp[11]);
				nunchukCalibData.accY_1g =  WII_DECRYPT(dp[12]);
				nunchukCalibData.accZ_1g =  WII_DECRYPT(dp[13]);
				
				nunchukJoyStickCalibData.x_max =  WII_DECRYPT(dp[15]);
				nunchukJoyStickCalibData.x_min =  WII_DECRYPT(dp[16]);
				nunchukJoyStickCalibData.x_center =  WII_DECRYPT(dp[17]);
				
				nunchukJoyStickCalibData.y_max =  WII_DECRYPT(dp[18]);
				nunchukJoyStickCalibData.y_min =  WII_DECRYPT(dp[19]);
				nunchukJoyStickCalibData.y_center =  WII_DECRYPT(dp[20]);	
				
				_shouldReadExpansionCalibration = NO;
				return;
			} else if (expType == WiiClassicController) {
				//classic controller calibration data (probably)
			}
		}
	} // expansion device calibration data
	
	// wiimote buttons
	buttonData = ((short)dp[2] << 8) + dp[3];
	[self sendWiiRemoteButtonEvent:buttonData];
} // handleRAMData

- (void) handleStatusReport:(unsigned char *) dp length:(size_t) dataLength
{
	NSLogDebug (@"Status Report (0x%x)", dp[4]);
		
	double level = (double) dp[7];
	level /= (double) 0xC0; // C0 = fully charged.

	if (level != _batteryLevel) {
		_batteryLevel = level;
		if ([_delegate respondsToSelector:@selector (batteryLevelChanged:)])
			[_delegate batteryLevelChanged:_batteryLevel];
	}
		
	if (_batteryLevel < _warningBatteryLevel)
		[[NSNotificationCenter defaultCenter] postNotificationName:@"WiiRemoteBatteryLowNotification" object:self];
		
	IOReturn ret = kIOReturnSuccess;
	if (dp[4] & 0x02) { //some device attached to Wiimote
		NSLogDebug (@"Device Attached");
		if (!_isExpansionPortAttached) {
      usleep (10000); // balance beam needs the time.
			ret = [self writeData:(darr){0x00} at:(unsigned long)0x04A40040 length:1]; // Initialize the device
			usleep (10000);

			if (ret != kIOReturnSuccess) {
				NSLogDebug (@"Problem occured while initializing the expansion port.");
				LogIOReturn (ret);
				return;
			}

			IOReturn ret = [self readData:0x04A400F0 length:16]; // read expansion device type
			LogIOReturn (ret);
			
			_isExpansionPortAttached = (ret == kIOReturnSuccess);
			
			if (ret == kIOReturnSuccess) {
				NSLogDebug (@"Expansion Device initialized");
			} else
				NSLogDebug (@"Failed to initialize Expansion Device");
			
			return;
		}
	} else { // unplugged
		if (_isExpansionPortAttached) {
			NSLogDebug (@"Device Detached");
			_isExpansionPortAttached = NO;
			expType = WiiExpNotAttached;

			[[NSNotificationCenter defaultCenter] postNotificationName:WiiRemoteExpansionPortChangedNotification object:self];
		}
	}

	_isLED1Illuminated = (dp[4] & 0x10);
	_isLED2Illuminated = (dp[4] & 0x20);
	_isLED3Illuminated = (dp[4] & 0x40);
	_isLED4Illuminated = (dp[4] & 0x80);
} // handleStatusReport

- (void) handleExtensionData:(unsigned char *) dp length:(size_t) dataLength
{
	unsigned char startByte;
	
	switch (dp[1]) {
		case 0x34 :
			startByte = 4;
			break;
		case 0x35 :
			startByte = 7;
			break;
		case 0x36 :
			startByte = 14;
			break;
		case 0x37 :
			startByte = 17;
			break;
		default:
			NSLogDebug (@"Unsupported Report mode for extension data.");
			return; // This shouldn't ever happen.
	}
	
	switch (expType) {
		case WiiNunchuk:
			nStickX		= WII_DECRYPT(dp[startByte +0]);
			nStickY		= WII_DECRYPT(dp[startByte +1]);
			nAccX		= WII_DECRYPT(dp[startByte +2]);
			nAccY		= WII_DECRYPT(dp[startByte +3]);
			nAccZ		= WII_DECRYPT(dp[startByte +4]);
			nButtonData	= WII_DECRYPT(dp[startByte +5]);

			[self sendWiiNunchukButtonEvent:nButtonData];
			
			if ([_delegate respondsToSelector:@selector (accelerationChanged:accX:accY:accZ:)])
				[_delegate accelerationChanged:WiiNunchukAccelerationSensor accX:nAccX accY:nAccY accZ:nAccZ];
				
			if ([_delegate respondsToSelector:@selector (joyStickChanged:tiltX:tiltY:)])
				[_delegate joyStickChanged:WiiNunchukJoyStick tiltX:nStickX tiltY:nStickY];
			
			break;
			
		case WiiClassicController:
			cButtonData = (unsigned short)((WII_DECRYPT(dp[startByte+4]) << 8) + WII_DECRYPT(dp[startByte+5]));

			cStickX1 = WII_DECRYPT(dp[startByte +0]) & 0x3F;
			cStickY1 = WII_DECRYPT(dp[startByte +1]) & 0x3F;
			
			cStickX2 =
				(((WII_DECRYPT(dp[startByte +0]) & 0xC0) >> 3) |
				 ((WII_DECRYPT(dp[startByte +1]) & 0xC0) >> 5) |
				 ((WII_DECRYPT(dp[startByte +2]) & 0x80) >> 7)) & 0x1F;
			cStickY2 = WII_DECRYPT(dp[startByte +2]) & 0x1F;
			
			cAnalogL =
				(((WII_DECRYPT(dp[startByte +2]) & 0x60) >> 2) |
				 ((WII_DECRYPT(dp[startByte +3]) & 0xE0) >> 5)) & 0x1F;
			cAnalogR =  WII_DECRYPT(dp[startByte +3]) & 0x1F;
			
			[self sendWiiClassicControllerButtonEvent:cButtonData];
			if ([_delegate respondsToSelector:@selector (joyStickChanged:tiltX:tiltY:)]) {
				[_delegate joyStickChanged:WiiClassicControllerLeftJoyStick tiltX:cStickX1 tiltY:cStickY1];
				[_delegate joyStickChanged:WiiClassicControllerRightJoyStick tiltX:cStickX2 tiltY:cStickY2];
			}
				
			if ([_delegate respondsToSelector:@selector (analogButtonChanged:amount:)]) {
				[_delegate analogButtonChanged:WiiClassicControllerLButton amount:cAnalogL];
				[_delegate analogButtonChanged:WiiClassicControllerRButton amount:cAnalogR];
			}			

			break;
		case WiiBalanceBeam:
			{
				startByte = 4;
				int tr = (unsigned short)((dp[startByte+0] << 8) + dp[startByte+1]);
				int br = (unsigned short)((dp[startByte+2] << 8) + dp[startByte+3]);
				int tl = (unsigned short)((dp[startByte+4] << 8) + dp[startByte+5]);
				int bl = (unsigned short)((dp[startByte+6] << 8) + dp[startByte+7]);
				if ([_delegate respondsToSelector:@selector (balanceBeamChangedTopRight:bottomRight:topLeft:bottomLeft:)]) {
					[_delegate balanceBeamChangedTopRight:tr - balanceBeamCalibData.quad[0].topRight
											  bottomRight:br - balanceBeamCalibData.quad[0].bottomRight
												  topLeft:tl - balanceBeamCalibData.quad[0].topLeft
											   bottomLeft:bl - balanceBeamCalibData.quad[0].bottomLeft];
				}
				if (balanceBeamCalibData.isInitialized &&
					[_delegate respondsToSelector:@selector (balanceBeamKilogramsChangedTopRight:bottomRight:topLeft:bottomLeft:)]) {
					float trKG = BBInterpolate(tr, balanceBeamCalibData.quad[0].topRight, balanceBeamCalibData.quad[1].topRight, balanceBeamCalibData.quad[2].topRight);
					float brKG = BBInterpolate(br, balanceBeamCalibData.quad[0].bottomRight, balanceBeamCalibData.quad[1].bottomRight, balanceBeamCalibData.quad[2].bottomRight);
					float tlKG = BBInterpolate(tl, balanceBeamCalibData.quad[0].topLeft, balanceBeamCalibData.quad[1].topLeft, balanceBeamCalibData.quad[2].topLeft);
					float blKG = BBInterpolate(bl, balanceBeamCalibData.quad[0].bottomLeft, balanceBeamCalibData.quad[1].bottomLeft, balanceBeamCalibData.quad[2].bottomLeft);
					[_delegate balanceBeamKilogramsChangedTopRight:trKG bottomRight:brKG topLeft:tlKG bottomLeft:blKG];
				}
			}
			break;
	}
} // handleExtensionData

- (void) handleIRData:(unsigned char *) dp length:(size_t) dataLength
{
//	NSLog(@"Handling IR Data for 0x%00x", dp[1]);	
	int i = 0;
	if (dp[1] == 0x33) { // 12 IR bytes
		int startByte = 0;
		for(i=0 ; i < 4 ; i++) { 
			startByte = 7 + 3 * i;
			irData[i].x = (dp[startByte +0] | ((dp[startByte +2] & 0x30) << 4)) & 0x3FF;
			irData[i].y = (dp[startByte +1] | ((dp[startByte +2] & 0xC0) << 2)) & 0x3FF;
			irData[i].s =  dp[startByte +2] & 0x0F;
		} 	
 	} else { // 10 IR bytes
		int shift = (dp[1] == 0x36) ? 4 : 7;
		int startByte = 0;
		int i;
		for (i=0; i < 2; i++) {
			startByte = shift + 5 * i;
			irData[2*i].x = (dp[startByte +0] | ((dp[startByte +2] & 0x30) << 4)) & 0x3FF;
			irData[2*i].y = (dp[startByte +1] | ((dp[startByte +2] & 0xC0) << 2)) & 0x3FF;
			irData[2*i].s = ((irData[2*i].x == irData[2*i].y) && (irData[2*i].x == 0x3FF)) ? 0x0F : 0x05;  // No size is given in 10 byte report.

			irData[(2*i)+1].x = (dp[startByte +3] | ((dp[startByte +2] & 0x03) << 8)) & 0x3FF;
			irData[(2*i)+1].y = (dp[startByte +4] | ((dp[startByte +2] & 0x0C) << 6)) & 0x3FF;
			irData[(2*i)+1].s = ((irData[(2*i)+1].x == irData[(2*i)+1].y) && (irData[(2*i)+1].x == 0x3FF)) ? 0x0F : 0x05;  // No size is given in 10 byte report.
		}
	}

//	NSLogDebug (@"IR Data (%i, %i, %i) (%i, %i, %i) (%i, %i, %i) (%i, %i, %i)",
//		  irData[0].x, irData[0].y, irData[0].s,
//		  irData[1].x, irData[1].y, irData[1].s,
//		  irData[2].x, irData[2].y, irData[2].s,
//		  irData[3].x, irData[3].y, irData[3].s);

	int p1 = -1;
	int p2 = -1;
	// we should modify this loop to take the points with the lowest s (the brightest ones)
	for (i=0 ; i<4 ; i++) {
		if (p1 == -1) {
			if (irData [i].s < 0x0F)
				p1 = i;
		} else {
			if (irData [i].s < 0x0F) {
				p2 = i;
				break;
			}
		}
	}
	
//	NSLogDebug (@"p1=%i ; p2=%i", p1, p2);

	double ox, oy;
	if ((p1 > -1) && (p2 > -1)) {
		int l = leftPoint;
		if (leftPoint == -1) {
			switch (orientation) {
				case 0: l = (irData[p1].x < irData[p2].x) ? 0 : 1; break;
				case 1: l = (irData[p1].y > irData[p2].y) ? 0 : 1; break;
				case 2: l = (irData[p1].x > irData[p2].x) ? 0 : 1; break;
				case 3: l = (irData[p1].y < irData[p2].y) ? 0 : 1; break;
			}

			leftPoint = l;
		}

		int r = 1-l;

		double dx = irData[r].x - irData[l].x;
		double dy = irData[r].y - irData[l].y;
		double d = hypot (dx, dy);

		dx /= d;
		dy /= d;

		double cx = (irData[l].x + irData[r].x)/kWiiIRPixelsWidth - 1;
		double cy = (irData[l].y + irData[r].y)/kWiiIRPixelsHeight - 1;

		ox = -dy*cy-dx*cx;
		oy = -dx*cy+dy*cx;

		// cam:
		// Compensate for distance. There must be fewer than 0.75*768 pixels between the spots for this to work.
		// In other words, you have to be far enough away from the sensor bar for the two spots to have enough
		// space on the image sensor to travel without one of the points going off the image.
		// note: it is working very well ...
		double gain = 4;
		if (d < (0.75 * kWiiIRPixelsHeight)) 
			gain = 1 / (1 - d/kWiiIRPixelsHeight);
		
		ox *= gain;
		oy *= gain;		
//		NSLog(@"x:%5.2f;  y: %5.2f;  angle: %5.1f\n", ox, oy, angle*180/M_PI);
	} else {
		ox = oy = -100;
		if (leftPoint != -1) {
			//	printf("Not tracking.\n");
			leftPoint = -1;
		}
	}
	
	if ([_delegate respondsToSelector:@selector (irPointMovedX:Y:)])
		[_delegate irPointMovedX:ox Y:oy];

	if ([_delegate respondsToSelector:@selector (rawIRData:)])
		[_delegate rawIRData:irData];
	
} // handleIRData

- (void) handleButtonReport:(unsigned char *) dp length:(size_t) dataLength
{
	// wiimote buttons
	buttonData = ((short)dp[2] << 8) + dp[3];
	[self sendWiiRemoteButtonEvent:buttonData];
				
	// report contains extension data		
	switch (dp[1]) {
		case 0x34:
		case 0x35:
		case 0x36:
		case 0x37:
			[self handleExtensionData:dp length:dataLength];
			break;
	}
	
	// report contains IR data
	if (dp[1] & 0x02) {
		[self handleIRData: dp length: dataLength];
	} // report contains IR data
	
	// report contains motion sensor data
	if (dp[1] & 0x01) {
		// cam: added 9th bit of resolution to the wii acceleration
		// see http://www.wiili.org/index.php/Talk:Wiimote#Remaining_button_state_bits
		//
		accX = (dp[4] << 1) | (buttonData & 0x0040) >> 6;
		accY = (dp[5] << 1) | (buttonData & 0x2000) >> 13;
		accZ = (dp[6] << 1) | (buttonData & 0x4000) >> 14;
		
		[_delegate accelerationChanged:WiiRemoteAccelerationSensor accX:accX accY:accY accZ:accZ];
		
		_lowZ = _lowZ * 0.9 + accZ * 0.1;
		_lowX = _lowX * 0.9 + accX * 0.1;
		
		float absx = fabsf (_lowX - WIR_HALFRANGE);
		float absz = fabsf (_lowZ - WIR_HALFRANGE);
		
		if (orientation == 0 || orientation == 2) absx -= WIR_INTERVAL;
		if (orientation == 1 || orientation == 3) absz -= WIR_INTERVAL;
		
		if (absz >= absx) {
			if (absz > WIR_INTERVAL)
				orientation = (_lowZ > WIR_HALFRANGE) ? 0 : 2;
		} else {
			if (absx > WIR_INTERVAL)
				orientation = (_lowX > WIR_HALFRANGE) ? 3 : 1;
		}
	} // report contains motion sensor data
} // handleButtonReport

- (void) sendWiiRemoteButtonEvent:(UInt16) data {
	if (data & kWiiRemoteTwoButton){
		if (!buttonState[WiiRemoteTwoButton]){
			buttonState[WiiRemoteTwoButton] = YES;
			[_delegate buttonChanged:WiiRemoteTwoButton isPressed:buttonState[WiiRemoteTwoButton]];
		}
	}else{
		if (buttonState[WiiRemoteTwoButton]){
			buttonState[WiiRemoteTwoButton] = NO;
			[_delegate buttonChanged:WiiRemoteTwoButton isPressed:buttonState[WiiRemoteTwoButton]];
		}
	}

	if (data & kWiiRemoteOneButton){
		if (!buttonState[WiiRemoteOneButton]){
			buttonState[WiiRemoteOneButton] = YES;
			[_delegate buttonChanged:WiiRemoteOneButton isPressed:buttonState[WiiRemoteOneButton]];
		}
	}else{
		if (buttonState[WiiRemoteOneButton]){
			buttonState[WiiRemoteOneButton] = NO;
			[_delegate buttonChanged:WiiRemoteOneButton isPressed:buttonState[WiiRemoteOneButton]];
		}
	}
	
	if (data & kWiiRemoteAButton){
		if (!buttonState[WiiRemoteAButton]){
			buttonState[WiiRemoteAButton] = YES;
			[_delegate buttonChanged:WiiRemoteAButton isPressed:buttonState[WiiRemoteAButton]];
		}
	}else{
		if (buttonState[WiiRemoteAButton]){
			buttonState[WiiRemoteAButton] = NO;
			[_delegate buttonChanged:WiiRemoteAButton isPressed:buttonState[WiiRemoteAButton]];
		}
	}
	
	if (data & kWiiRemoteBButton){
		if (!buttonState[WiiRemoteBButton]){
			buttonState[WiiRemoteBButton] = YES;
			[_delegate buttonChanged:WiiRemoteBButton isPressed:buttonState[WiiRemoteBButton]];
		}
	}else{
		if (buttonState[WiiRemoteBButton]){
			buttonState[WiiRemoteBButton] = NO;
			[_delegate buttonChanged:WiiRemoteBButton isPressed:buttonState[WiiRemoteBButton]];
		}
	}
	
	if (data & kWiiRemoteMinusButton){
		if (!buttonState[WiiRemoteMinusButton]){
			buttonState[WiiRemoteMinusButton] = YES;
			[_delegate buttonChanged:WiiRemoteMinusButton isPressed:buttonState[WiiRemoteMinusButton]];
		}
	}else{
		if (buttonState[WiiRemoteMinusButton]){
			buttonState[WiiRemoteMinusButton] = NO;
			[_delegate buttonChanged:WiiRemoteMinusButton isPressed:buttonState[WiiRemoteMinusButton]];
		}
	}
	
	if (data & kWiiRemoteHomeButton){
		if (!buttonState[WiiRemoteHomeButton]){
			buttonState[WiiRemoteHomeButton] = YES;
			[_delegate buttonChanged:WiiRemoteHomeButton isPressed:buttonState[WiiRemoteHomeButton]];
		}
	}else{
		if (buttonState[WiiRemoteHomeButton]){
			buttonState[WiiRemoteHomeButton] = NO;
			[_delegate buttonChanged:WiiRemoteHomeButton isPressed:buttonState[WiiRemoteHomeButton]];
		}
	}
	
	if (data & kWiiRemotePlusButton){
		if (!buttonState[WiiRemotePlusButton]){
			buttonState[WiiRemotePlusButton] = YES;
			[_delegate buttonChanged:WiiRemotePlusButton isPressed:buttonState[WiiRemotePlusButton]];
		}
	}else{
		if (buttonState[WiiRemotePlusButton]){
			buttonState[WiiRemotePlusButton] = NO;
			[_delegate buttonChanged:WiiRemotePlusButton isPressed:buttonState[WiiRemotePlusButton]];
		}
	}
	
	if (data & kWiiRemoteUpButton){
		if (!buttonState[WiiRemoteUpButton]){
			buttonState[WiiRemoteUpButton] = YES;
			[_delegate buttonChanged:WiiRemoteUpButton isPressed:buttonState[WiiRemoteUpButton]];
		}
	}else{
		if (buttonState[WiiRemoteUpButton]){
			buttonState[WiiRemoteUpButton] = NO;
			[_delegate buttonChanged:WiiRemoteUpButton isPressed:buttonState[WiiRemoteUpButton]];
		}
	}
	
	if (data & kWiiRemoteDownButton){
		if (!buttonState[WiiRemoteDownButton]){
			buttonState[WiiRemoteDownButton] = YES;
			[_delegate buttonChanged:WiiRemoteDownButton isPressed:buttonState[WiiRemoteDownButton]];
		}
	}else{
		if (buttonState[WiiRemoteDownButton]){
			buttonState[WiiRemoteDownButton] = NO;
			[_delegate buttonChanged:WiiRemoteDownButton isPressed:buttonState[WiiRemoteDownButton]];
		}
	}

	if (data & kWiiRemoteLeftButton){
		if (!buttonState[WiiRemoteLeftButton]){
			buttonState[WiiRemoteLeftButton] = YES;
			[_delegate buttonChanged:WiiRemoteLeftButton isPressed:buttonState[WiiRemoteLeftButton]];
		}
	}else{
		if (buttonState[WiiRemoteLeftButton]){
			buttonState[WiiRemoteLeftButton] = NO;
			[_delegate buttonChanged:WiiRemoteLeftButton isPressed:buttonState[WiiRemoteLeftButton]];
		}
	}
	
	
	if (data & kWiiRemoteRightButton){
		if (!buttonState[WiiRemoteRightButton]){
			buttonState[WiiRemoteRightButton] = YES;
			[_delegate buttonChanged:WiiRemoteRightButton isPressed:buttonState[WiiRemoteRightButton]];
		}
	}else{
		if (buttonState[WiiRemoteRightButton]){
			buttonState[WiiRemoteRightButton] = NO;
			[_delegate buttonChanged:WiiRemoteRightButton isPressed:buttonState[WiiRemoteRightButton]];
		}
	}
}

- (void)sendWiiNunchukButtonEvent:(UInt16)data{
	if (!(data & kWiiNunchukCButton)){
		if (!buttonState[WiiNunchukCButton]){
			buttonState[WiiNunchukCButton] = YES;
			[_delegate buttonChanged:WiiNunchukCButton isPressed:buttonState[WiiNunchukCButton]];
		}
	}else{
		if (buttonState[WiiNunchukCButton]){
			buttonState[WiiNunchukCButton] = NO;
			[_delegate buttonChanged:WiiNunchukCButton isPressed:buttonState[WiiNunchukCButton]];
		}
	}
	
	if (!(data & kWiiNunchukZButton)){

		if (!buttonState[WiiNunchukZButton]){
			buttonState[WiiNunchukZButton] = YES;
			[_delegate buttonChanged:WiiNunchukZButton isPressed:buttonState[WiiNunchukZButton]];
		}
	}else{
		if (buttonState[WiiNunchukZButton]){
			buttonState[WiiNunchukZButton] = NO;
			[_delegate buttonChanged:WiiNunchukZButton isPressed:buttonState[WiiNunchukZButton]];
		}
	}
}

- (void)sendWiiClassicControllerButtonEvent:(UInt16)data{
	if (!(data & kWiiClassicControllerXButton)){
		
		if (!buttonState[WiiClassicControllerXButton]){
			buttonState[WiiClassicControllerXButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerXButton isPressed:buttonState[WiiClassicControllerXButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerXButton]){
			buttonState[WiiClassicControllerXButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerXButton isPressed:buttonState[WiiClassicControllerXButton]];
			
		}
	}

	if (!(data & kWiiClassicControllerYButton)){
		
		if (!buttonState[WiiClassicControllerYButton]){
			buttonState[WiiClassicControllerYButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerYButton isPressed:buttonState[WiiClassicControllerYButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerYButton]){
			buttonState[WiiClassicControllerYButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerYButton isPressed:buttonState[WiiClassicControllerYButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerAButton)){
		
		if (!buttonState[WiiClassicControllerAButton]){
			buttonState[WiiClassicControllerAButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerAButton isPressed:buttonState[WiiClassicControllerAButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerAButton]){
			buttonState[WiiClassicControllerAButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerAButton isPressed:buttonState[WiiClassicControllerAButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerBButton)){
		
		if (!buttonState[WiiClassicControllerBButton]){
			buttonState[WiiClassicControllerBButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerBButton isPressed:buttonState[WiiClassicControllerBButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerBButton]){
			buttonState[WiiClassicControllerBButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerBButton isPressed:buttonState[WiiClassicControllerBButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerLButton)){
		
		if (!buttonState[WiiClassicControllerLButton]){
			buttonState[WiiClassicControllerLButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerLButton isPressed:buttonState[WiiClassicControllerLButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerLButton]){
			buttonState[WiiClassicControllerLButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerLButton isPressed:buttonState[WiiClassicControllerLButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerRButton)){
		
		if (!buttonState[WiiClassicControllerRButton]){
			buttonState[WiiClassicControllerRButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerRButton isPressed:buttonState[WiiClassicControllerRButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerRButton]){
			buttonState[WiiClassicControllerRButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerRButton isPressed:buttonState[WiiClassicControllerRButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerZLButton)){
		
		if (!buttonState[WiiClassicControllerZLButton]){
			buttonState[WiiClassicControllerZLButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerZLButton isPressed:buttonState[WiiClassicControllerZLButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerZLButton]){
			buttonState[WiiClassicControllerZLButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerZLButton isPressed:buttonState[WiiClassicControllerZLButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerZRButton)){
		
		if (!buttonState[WiiClassicControllerZRButton]){
			buttonState[WiiClassicControllerZRButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerZRButton isPressed:buttonState[WiiClassicControllerZRButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerZRButton]){
			buttonState[WiiClassicControllerZRButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerZRButton isPressed:buttonState[WiiClassicControllerZRButton]];
			
		}
	}
	
	
	if (!(data & kWiiClassicControllerUpButton)){
		
		if (!buttonState[WiiClassicControllerUpButton]){
			buttonState[WiiClassicControllerUpButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerUpButton isPressed:buttonState[WiiClassicControllerUpButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerUpButton]){
			buttonState[WiiClassicControllerUpButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerUpButton isPressed:buttonState[WiiClassicControllerUpButton]];
			
		}
	}
	
	
	if (!(data & kWiiClassicControllerDownButton)){
		
		if (!buttonState[WiiClassicControllerDownButton]){
			buttonState[WiiClassicControllerDownButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerDownButton isPressed:buttonState[WiiClassicControllerDownButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerDownButton]){
			buttonState[WiiClassicControllerDownButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerDownButton isPressed:buttonState[WiiClassicControllerDownButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerLeftButton)){
		
		if (!buttonState[WiiClassicControllerLeftButton]){
			buttonState[WiiClassicControllerLeftButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerLeftButton isPressed:buttonState[WiiClassicControllerLeftButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerLeftButton]){
			buttonState[WiiClassicControllerLeftButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerLeftButton isPressed:buttonState[WiiClassicControllerLeftButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerRightButton)){
		
		if (!buttonState[WiiClassicControllerRightButton]){
			buttonState[WiiClassicControllerRightButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerRightButton isPressed:buttonState[WiiClassicControllerRightButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerRightButton]){
			buttonState[WiiClassicControllerRightButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerRightButton isPressed:buttonState[WiiClassicControllerRightButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerMinusButton)){
		
		if (!buttonState[WiiClassicControllerMinusButton]){
			buttonState[WiiClassicControllerMinusButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerMinusButton isPressed:buttonState[WiiClassicControllerMinusButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerMinusButton]){
			buttonState[WiiClassicControllerMinusButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerMinusButton isPressed:buttonState[WiiClassicControllerMinusButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerHomeButton)){
		
		if (!buttonState[WiiClassicControllerHomeButton]){
			buttonState[WiiClassicControllerHomeButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerHomeButton isPressed:buttonState[WiiClassicControllerHomeButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerHomeButton]){
			buttonState[WiiClassicControllerHomeButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerHomeButton isPressed:buttonState[WiiClassicControllerHomeButton]];
			
		}
	}
	
	if (!(data & kWiiClassicControllerPlusButton)){
		
		if (!buttonState[WiiClassicControllerPlusButton]){
			buttonState[WiiClassicControllerPlusButton] = YES;
			[_delegate buttonChanged:WiiClassicControllerPlusButton isPressed:buttonState[WiiClassicControllerPlusButton]];
		}
	}else{
		if (buttonState[WiiClassicControllerPlusButton]){
			buttonState[WiiClassicControllerPlusButton] = NO;
			[_delegate buttonChanged:WiiClassicControllerPlusButton isPressed:buttonState[WiiClassicControllerPlusButton]];
			
		}
	}
}

- (IOReturn) getMii:(unsigned int) slot
{
	mii_data_offset = 0;
	return [self readData:MII_OFFSET(slot) length:WIIMOTE_MII_DATA_BYTES_PER_SLOT];
}

- (IOReturn) getCurrentStatus:(NSTimer*) timer
{
	unsigned char cmd[] = {0x15, 0x00};
	IOReturn ret = [self sendCommand:cmd length:2];
	if (ret != kIOReturnSuccess)
		NSLogDebug (@"getCurrentStatus: failed.");
	
	return ret;
}

- (WiiExpansionPortType) expansionPortType
{
	return expType;
}

- (BOOL) isExpansionPortAttached
{
	return _isExpansionPortAttached;
}

- (BOOL)isButtonPressed:(WiiButtonType) type
{
	return buttonState[type];
}

- (WiiJoyStickCalibData) joyStickCalibData:(WiiJoyStickType) type
{
	switch (type) {
		case WiiNunchukJoyStick:
			return nunchukJoyStickCalibData;
		default:
			return kWiiNullJoystickCalibData;
	}
}

- (WiiAccCalibData) accCalibData:(WiiAccelerationSensorType) type
{
	switch (type) {
		case WiiRemoteAccelerationSensor:
			return wiiCalibData;
		case WiiNunchukAccelerationSensor:
			return nunchukCalibData;
		default:
			return kWiiNullAccCalibData;
	}
}

/*============= BluetoothChannel Delegate methods ================*/

- (void) l2capChannelReconfigured:(IOBluetoothL2CAPChannel*) l2capChannel
{
      NSLogDebug (@"l2capChannelReconfigured");
}

- (void) l2capChannelWriteComplete:(IOBluetoothL2CAPChannel*) l2capChannel refcon:(void*) refcon status:(IOReturn) error
{
      NSLogDebug (@"l2capChannelWriteComplete");
}

- (void) l2capChannelQueueSpaceAvailable:(IOBluetoothL2CAPChannel*) l2capChannel
{
      NSLogDebug (@"l2capChannelQueueSpaceAvailable");
}

- (void) l2capChannelOpenComplete:(IOBluetoothL2CAPChannel*) l2capChannel status:(IOReturn) error
{
	NSLogDebug (@"l2capChannelOpenComplete (PSM:0x%x)", [l2capChannel getPSM]);
}

- (void) l2capChannelClosed:(IOBluetoothL2CAPChannel*) l2capChannel
{
	NSLogDebug (@"l2capChannelClosed (PSM:0x%x)", [l2capChannel getPSM]);

	if (l2capChannel == _cchan)
		_cchan = nil;

	if (l2capChannel == _ichan)
		_ichan = nil;
	
	[self closeConnection];
} 

// thanks to Ian!
- (void) l2capChannelData:(IOBluetoothL2CAPChannel*) l2capChannel data:(void *) dataPointer length:(size_t) dataLength
{	
	if (!([self available] && _opened)) {
//		[self closeConnection];
		return;
	}

	unsigned char * dp = (unsigned char *) dataPointer;
	
/*	if (_dump) {
		NSLogDebug (@"Dumping: 0x%x", dp[1]);
		Debugger();
	}*/

	if ([_delegate respondsToSelector:@selector (wiimoteWillSendData)])
		[_delegate wiimoteWillSendData];
	
	// controller status (expansion port and battery level data) - received when report 0x15 sent to Wiimote (getCurrentStatus:) or status of expansion port changes.
	if (dp[1] == 0x20 && dataLength >= 8) {
		[self handleStatusReport:dp length:dataLength];
//		[self updateReportMode]; // Make sure we keep getting state change reports.
	} else if (dp[1] == 0x21) { // read data response
		[self handleRAMData:dp length:dataLength];
	} else if (dp[1] == 0x22) { // Write data response
		[self handleWriteResponse:dp length:dataLength];
	} else if ((dp[1] & 0xF0) == 0x30) {
		// report contains button info
		[self handleButtonReport:dp length:dataLength];
	}
	
	if ([_delegate respondsToSelector:@selector (wiimoteDidSendData)])
		[_delegate wiimoteDidSendData];

  if (_isExpansionPortEnabled) {
    IOReturn ret = [self doUpdateReportMode];
    if (ret != kIOReturnSuccess) {
      _shouldUpdateReportMode = YES;
      [self doUpdateReportMode];
      
      if (ret != kIOReturnSuccess) {
        NSLogDebug (@"Can't update report mode after two retries, bailing out.");
        [self closeConnection];
        return;
      }
    }
  }
//	NSLogDebug (@"Unhandled data received: 0x%x", dp[1]);
	//if (nil != _delegate)
		//[_delegate dataChanged:buttonData accX:accX accY:accY accZ:accZ mouseX:ox mouseY:oy];
	//[_delegate dataChanged:buttonData accX:irData[0].x/4 accY:irData[0].y/3 accZ:irData[0].s*16];
} // l2capChannelData

@end


@implementation WiiRemote (Private)

- (IOBluetoothL2CAPChannel *) openL2CAPChannelWithPSM:(BluetoothL2CAPPSM) psm delegate:(id) delegate
{
	IOBluetoothL2CAPChannel * channel = nil;
	IOReturn ret = kIOReturnSuccess;
	
	NSLogDebug(@"Open channel (PSM:%i) ...", psm);
	if ((ret = [_wiiDevice openL2CAPChannelSync:&channel withPSM:psm delegate:delegate]) != kIOReturnSuccess) {
//	if ((ret = [_wiiDevice openL2CAPChannel:psm findExisting:NO newChannel:&channel]) != kIOReturnSuccess) {
		NSLogDebug (@"Could not open L2CAP channel (psm:%i)", psm);
		LogIOReturn (ret);
		channel = nil;
		[self closeConnection];
	} else {
        channel = [channel retain];
    }
	
	return channel;
}

@end


// end of file
