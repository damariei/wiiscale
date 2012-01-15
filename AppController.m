#import "AppController.h"

@implementation AppController

#pragma mark Preferences

- (IBAction)showPrefs:(id)sender
{
	[NSApp beginSheet:prefs modalForWindow:self.window modalDelegate:self didEndSelector:@selector(didEndSheet:returnCode:contextInfo:) contextInfo:nil];	
}

- (void)didEndSheet:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	[sheet orderOut:self];
	
	NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:@"username"];
	NSString *password = [[NSUserDefaults standardUserDefaults] stringForKey:@"password"];
	
	if(username.length && password.length)
		[self performSelector:@selector(loginGoogleHealth:) withObject:self afterDelay:0.0f];	
}

#pragma mark Window

- (id)init
{
    self = [super init];
    if (self) {
		
		weightSampleIndex = 0;
				
		service = [[GDataServiceGoogleHealth alloc] init];
		[service setUserAgent:@"FordParsons-WiiScaleMac-1.0"];
		[service setShouldCacheDatedData:YES];
		[service setServiceShouldFollowNextLinks:YES];
		
		NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:@"username"];
		NSString *password = [[NSUserDefaults standardUserDefaults] stringForKey:@"password"];
		
		if(username.length && password.length)
			[self performSelector:@selector(loginGoogleHealth:) withObject:self afterDelay:0.0f];
		else
			[self performSelector:@selector(showPrefs:) withObject:self afterDelay:0.0f];
		
		[self performSelectorInBackground:@selector(showMessage) withObject:nil];
		
		if(!discovery) {
			[self performSelector:@selector(doDiscovery:) withObject:self afterDelay:0.0f];
		}
		
		mailSent = [[NSSound alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"mail-sent" ofType:@"aiff"] byReference:NO];
		
    }
    return self;
}

- (void)dealloc
{
	[super dealloc];
	[mailSent release];
	[service release];
	[profiles release];
}

- (void)awakeFromNib {

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

#pragma mark NSApplication

- (void)applicationWillTerminate:(NSNotification *)notification
{
	[wii closeConnection];
}

#pragma mark Google

- (void)loginGoogleHealth:(id)sender {
	
	[ghspinner startAnimation:self];
	
	// username/password may change
	NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:@"username"];
	NSString *password = [[NSUserDefaults standardUserDefaults] stringForKey:@"password"];
	
	if(username.length && password.length) {
		
		[service setUserCredentialsWithUsername:username
									   password:password];
		
		[service fetchFeedWithURL:[[GDataServiceGoogleHealth class] profileListFeedURL]
						 delegate:self
				didFinishSelector:@selector(profileListFeedTicket:finishedWithFeed:error:)];
	}
}

- (void)profileListFeedTicket:(GDataServiceTicket *)ticket
             finishedWithFeed:(GDataFeedBase *)feed
                        error:(NSError *)error {
	
	[ghspinner stopAnimation:self];
		
	if(!error) {
		[profiles release];
		profiles = [feed retain];

		[profilesPopUp removeAllItems];
		for(GDataEntryHealthProfile* p in [profiles entries])
			[profilesPopUp addItemWithTitle:[[p title] stringValue]];
		
		NSString *profileName = [[NSUserDefaults standardUserDefaults] stringForKey:@"profileName"];
		if(profileName.length && !![profilesPopUp itemWithTitle:profileName]) {
			[profilesPopUp selectItemWithTitle:profileName];
			[self profileChanged:profilesPopUp];
		}
		
	} else {
		[[NSAlert alertWithError:error] runModal]; // TODO: nicer errors?
	}
}

- (IBAction)profileChanged:(id)sender {
	[[NSUserDefaults standardUserDefaults] setValue:[(NSPopUpButton *)sender titleOfSelectedItem] forKey:@"profileName"];
	[[NSUserDefaults standardUserDefaults] synchronize];
	
	[ghspinner startAnimation:self];

	NSString *profileId = [[(GDataEntryHealthProfile *)[[profiles entries] objectAtIndex:[profilesPopUp indexOfSelectedItem]] content] stringValue];

	GDataQueryGoogleHealth *query = [GDataQueryGoogleHealth queryWithFeedURL:[GDataServiceGoogleHealth profileFeedURLForProfileID:profileId]];
	[query addCategoryFilterWithScheme:nil term:@"LABTEST"];	
	[query addCategoryFilterWithScheme:kGDataHealthSchemeItem term:@"Height"];
	[query setIsGrouped:YES];
	[query setMaxResultsInGroup:1];
	
	[service fetchFeedWithQuery:query
					   delegate:self
			  didFinishSelector:@selector(profileDetailFeedTicket:finishedWithFeed:error:)];	
	
}

- (void)profileDetailFeedTicket:(GDataServiceTicket *)ticket
			   finishedWithFeed:(GDataFeedBase *)feed
						  error:(NSError *)error {

	[ghspinner stopAnimation:self];
	
	height_cm = 0;

	for(GDataEntryHealthProfile *entry in feed.entries) {
		
		// Skip the no_id nodes
		if(![entry.title.stringValue isEqualToString:@"Height"] || height_cm > 0)
			continue;

		NSXMLElement *elem = [[[entry continuityOfCareRecord] XMLDocument] rootElement];
		NSArray *nodes_cm = [elem nodesForXPath:@"/ContinuityOfCareRecord/Body/Results/Result/Test[Description/Text='Height']/TestResult[Units/Unit='centimeters']/Value/text()" error:nil];
		NSArray *nodes_in = [elem nodesForXPath:@"/ContinuityOfCareRecord/Body/Results/Result/Test[Description/Text='Height']/TestResult[Units/Unit='inches']/Value/text()" error:nil];

		height_cm = ([nodes_cm count] > 0) ? [[[nodes_cm lastObject] XMLString] floatValue] : ([nodes_in count] > 0) ? [[[nodes_in lastObject] XMLString] floatValue] * 2.54 : 0;
	}
	
	if(height_cm > 0) {
		float height_m_2 = pow(height_cm / 100.0, 2);
		
		[weightIndicator setLowCriticalValue:16.5 * height_m_2]; // Min Underweight
		[weightIndicator setLowWarningValue:18.5 * height_m_2]; // Min Normal
		[weightIndicator setHighWarningValue:25.0 * height_m_2]; // Max Normal
		[weightIndicator setHighCriticalValue:30.0 * height_m_2]; // Max Overweight
		[weightIndicator setMaxValue:40.0 * height_m_2]; // Obese Class III
	} else {
		[weightIndicator setLowCriticalValue:0.0];
		[weightIndicator setLowWarningValue:0.0];
		[weightIndicator setHighWarningValue:150.0];
		[weightIndicator setHighCriticalValue:150.0];
		[weightIndicator setMaxValue:150.0];
	}
}

- (void)sendToGoogleHealth:(id)sender {
	
	if(!service)
		[self loginGoogleHealth:self];
	
	sentWeight = avgWeight;
	
	GDataEntryHealthProfile *entry = [[[GDataEntryHealthProfile alloc] init] autorelease];
	
	NSString *format = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"weight" ofType:@"xml"] encoding:NSUTF8StringEncoding error:nil];
	NSString *ccr = [NSString stringWithFormat:format,
					 [[GDataDateTime dateTimeWithDate:[NSDate date] timeZone:[NSTimeZone localTimeZone]] RFC3339String],
					 sentWeight];	 

	[entry setContinuityOfCareRecord:[[[GDataContinuityOfCareRecord alloc] initWithXMLElement:
									   [[[NSXMLElement alloc] initWithXMLString:ccr
																		  error:nil] autorelease] parent:nil] autorelease]];
	
	[entry setTitleWithString:@"Weight Update from WiiScale"];
	
	[service fetchEntryByInsertingEntry:entry
							 forFeedURL:[GDataServiceGoogleHealth registerFeedURLForProfileID:[[(GDataEntryHealthProfile *)[[profiles entries] objectAtIndex:[profilesPopUp indexOfSelectedItem]] content] stringValue]]
							   delegate:self
					  didFinishSelector:@selector(fetchEntryByInsertingEntry:finishedWithEntry:error:)];	
}

- (void)fetchEntryByInsertingEntry:(GDataServiceTicket *)ticket
				 finishedWithEntry:(GDataFeedBase *)feed
							 error:(NSError *)error {
	
	if(!!error)
	{
		[[NSAlert alertWithError:error] runModal]; // TODO: nicer error?
		
	}
	else
	{
		[mailSent play];
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
			[status setStringValue:[NSString stringWithFormat:@"Sent weight of %4.1fkg.  Thanks!", sentWeight]];

		
		if(std_dev < 0.1 && !sent)
		{
			sent = YES;
			[self sendToGoogleHealth:self];
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
