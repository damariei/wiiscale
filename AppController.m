#import "AppController.h"

@implementation AppController

#pragma mark Preferences

- (IBAction)showPrefs:(id)sender
{
    
    
    if ([profilesPopUp indexOfSelectedItem] < [profilesPopUp itemArray].count-2) {
        [[NSUserDefaults standardUserDefaults] setValue:profilesPopUp.selectedItem.title forKey:@"username"];
        prefsController.newUser = false;
    } else {
        [prefsController.userText setStringValue:@""];
        [profilesPopUp selectItemAtIndex:0];
        prefsController.newUser = true;
    }
    
    NSString *username;
    
    if (prefsController.newUser) {
        username = @"";
        prefsController.addOrDeleteBtn.title = @"Add";
        [prefsController.userText setEnabled:true];
    } else {
        username = [[NSUserDefaults standardUserDefaults] stringForKey:@"username"];
        prefsController.addOrDeleteBtn.title = @"Delete";
        [prefsController.userText setEnabled:false];
    }
    
	if(username.length)
		[prefsController.userText setStringValue:username];
    
	[NSApp beginSheet:prefs modalForWindow:self.window modalDelegate:self didEndSelector:@selector(didEndSheet:returnCode:contextInfo:) contextInfo:nil];
}

- (void)didEndSheet:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	[sheet orderOut:self];
	
    if (!prefsController.didCancel) {
        NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:@"username"];
        
        if (username.length) {
            [profilesPopUp insertItemWithTitle:username atIndex:0];
            [profilesPopUp selectItemAtIndex:0];
            [profiles addObject:username];
        } else {
            [profilesPopUp removeItemAtIndex:[profilesPopUp indexOfSelectedItem]];
            [profiles removeObject:[prefsController.userText stringValue]];
        }
        
        if ([profilesPopUp itemArray].count>2) {
            [profileButton setEnabled:true];
        } else {
            [profileButton setEnabled:false];
        }
    }
    
}

#pragma mark Window

- (id)init
{
    self = [super init];
    if (self) {
		
		weightSampleIndex = 0;
        
        // Load TextStrings.plist
        NSString* plistPath = [[NSBundle mainBundle] pathForResource:@"TextStrings" ofType:@"plist"];
        strings = [[NSDictionary dictionaryWithContentsOfFile:plistPath] copy];
        
        // Load Stored Profiles
        profiles = [[NSMutableArray alloc] 
                    initWithArray:[self getFromStorage]];
            
		[self performSelectorInBackground:@selector(showMessage) withObject:nil];
		
		if(!discovery) {
			[self performSelector:@selector(doDiscovery:) withObject:self afterDelay:0.0f];
		}
    
		
    }
    return self;
}

- (void)dealloc
{
	[super dealloc];
	[profiles dealloc];
}

- (void)awakeFromNib {
    
    // Init. Profiles Popup
    for (int i=0; i < [profiles count]; i++)
        [profilesPopUp addItemWithTitle:[profiles objectAtIndex:i]];
    
    if (profiles.count>0) {
        [profileButton setEnabled:true];
    }
    
    [[profilesPopUp menu] addItem:[NSMenuItem separatorItem]];
    [profilesPopUp addItemWithTitle:[self stringForKey:@"AddUser"]];
    
    
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(expansionPortChanged:)
												 name:@"WiiRemoteExpansionPortChangedNotification"
											   object:nil];
}

- (void)showMessage
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSDictionary *d = [NSDictionary dictionaryWithContentsOfURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://snosrap.com/wiiscale/message%@.plist", [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"]]]];
	if(!!d)
		[self performSelectorOnMainThread:@selector(showMessage:) withObject:d waitUntilDone:NO];

	[pool release];
}

- (void)showMessage:(NSDictionary *)d
{
	[[NSAlert alertWithMessageText:[d objectForKey:@"Title"] defaultButton:@"Okay" alternateButton:nil otherButton:nil informativeTextWithFormat:[d objectForKey:@"Message"]] runModal];
}
     
- (NSString*)stringForKey:(NSString *)key {
    return [NSString stringWithString:[strings objectForKey:key]];
}

- (NSArray*)getFromStorage {
    NSString *stringArray = [[NSUserDefaults standardUserDefaults] objectForKey:@"profiles"];
    if (stringArray.length) {
        return [stringArray componentsSeparatedByString:@"|"];
    } else {
        return [NSArray array];
    }
}

- (void)setToStorage:(NSArray *)storeArray {
    NSMutableString *stringArray = [NSMutableString stringWithCapacity:0];
    
    for (int i=0; i < storeArray.count; i++) {
        [stringArray appendString:[storeArray objectAtIndex:i]];
        
        if (i < storeArray.count-1)
            [stringArray appendString:@"|"];
    }
    [[NSUserDefaults standardUserDefaults] setValue:stringArray forKey:@"profiles"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark NSApplication

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self setToStorage:profiles];
	[wii closeConnection];
}

#pragma mark Profiles

- (IBAction)profileChanged:(id)sender {
	if ([[profilesPopUp selectedItem].title
          isEqualToString:[self stringForKey:@"AddUser"]]) {
        [self showPrefs:self];
    }
    
}

#pragma mark Wii Balance Board

- (IBAction)doDiscovery:(id)sender {
	
	if(!discovery) {
		discovery = [[WiiRemoteDiscovery alloc] init];
		[discovery setDelegate:self];
		[discovery start];
		
		[spinner startAnimation:self];
		[bbstatus setStringValue:@"Searching..."];
		[fileConnect setTitle:@"Stop Searching for Balance Board"];
		[status setStringValue:@"Press the red 'sync' button..."];
	} else {
		[discovery stop];
		[discovery release];
		discovery = nil;
		
		if(wii) {
			[wii closeConnection];
			[wii release];
			wii = nil;
		}
		
		[spinner stopAnimation:self];
		[bbstatus setStringValue:@"Disconnected"];
		[fileConnect setTitle:@"Connect to Balance Board"];
		[status setStringValue:@""];
	}
}

- (IBAction)doTare:(id)sender {
	tare = 0.0 - lastWeight;
}

#pragma mark Magic?

- (void)expansionPortChanged:(NSNotification *)nc{

	WiiRemote* tmpWii = (WiiRemote*)[nc object];
	
	// Check that the Wiimote reporting is the one we're connected to.
	if (![[tmpWii address] isEqualToString:[wii address]]){
		return;
	}
	
	if ([wii isExpansionPortAttached]){
		[wii setExpansionPortEnabled:YES];
	}	
}

#pragma mark WiiRemoteDelegate methods

- (void) buttonChanged:(WiiButtonType) type isPressed:(BOOL) isPressed
{	
	[self doTare:self];
}

- (void) wiiRemoteDisconnected:(IOBluetoothDevice*) device
{	
	[spinner stopAnimation:self];
	[bbstatus setStringValue:@"Disconnected"];
	
	[device closeConnection];
}

#pragma mark WiiRemoteDelegate methods (optional)

// cooked values from the Balance Beam
- (void) balanceBeamKilogramsChangedTopRight:(float)topRight
                                 bottomRight:(float)bottomRight
                                     topLeft:(float)topLeft
                                  bottomLeft:(float)bottomLeft {
	
	lastWeight = topRight + bottomRight + topLeft + bottomLeft;
	
	if(!tare) {
		[self doTare:self];
	}
	
	float trueWeight = lastWeight + tare;
	[weightIndicator setDoubleValue:trueWeight];
	
	if(trueWeight > 10.0) {
		weightSamples[weightSampleIndex] = trueWeight;
		weightSampleIndex = (weightSampleIndex + 1) % 100;
		
		float sum = 0;
		float sum_sqrs = 0;
		
		for (int i = 0; i < 100; i++)
		{
			sum += weightSamples[i];
			sum_sqrs += weightSamples[i] * weightSamples[i];
		}
		
		avgWeight = sum / 100.0;
		float var = sum_sqrs / 100.0 - (avgWeight * avgWeight);
		float std_dev = sqrt(var);

		if(!sent)
			[status setStringValue:@"Please hold still..."];
		else
			[status setStringValue:[NSString stringWithFormat:@"Sent weight of %4.1fkg.  Thanks!", avgWeight]];

		
		if(std_dev < 0.1 && !sent)
		{
			sent = YES;
		}
		
	} else {
		sent = NO;
		[status setStringValue:@"Tap the button to tare, then step on..."];
	}

	[weight setStringValue:[NSString stringWithFormat:@"%4.1fkg  %4.1flbs", MAX(0.0, trueWeight), MAX(0.0, (trueWeight) * 2.20462262)]];
}

#pragma mark WiiRemoteDiscoveryDelegate methods

- (void) WiiRemoteDiscovered:(WiiRemote*)wiimote {
	
	[wii release];
	wii = [wiimote retain];
	[wii setDelegate:self];

	[spinner stopAnimation:self];
	[bbstatus setStringValue:@"Connected"];
	
	[status setStringValue:@"Tap the button to tare, then step on..."];
}

- (void) WiiRemoteDiscoveryError:(int)code {
	
	NSLog(@"Error: %u", code);
		
	// Keep trying...
	[spinner stopAnimation:self];
	[discovery stop];
	sleep(1);
	[discovery start];
	[spinner startAnimation:self];
}

- (void) willStartWiimoteConnections {

}
@end
