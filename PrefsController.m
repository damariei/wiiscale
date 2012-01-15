//
//  PrefsController.m
//  GoogleHealthWeight
//
//  Created by Ford Parsons on 10/10/10.
//  Copyright 2010 Ford Parsons. All rights reserved.
//

#import "PrefsController.h"


@implementation PrefsController


- (void)awakeFromNib {

	NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:@"username"];
	NSString *password = [[NSUserDefaults standardUserDefaults] stringForKey:@"password"];
	
	if(!!username.length)
		[userText setStringValue:username];
	if(!!password.length)
		[passText setStringValue:password];
}

- (IBAction)closePrefs:(id)sender {
	[NSApp endSheet:configureSheet];
}

- (IBAction)saveAndClosePrefs:(id)sender {
	
	[[NSUserDefaults standardUserDefaults] setValue:[userText stringValue] forKey:@"username"];
	[[NSUserDefaults standardUserDefaults] setValue:[passText stringValue] forKey:@"password"];
	[[NSUserDefaults standardUserDefaults] synchronize];
	
	[NSApp endSheet:configureSheet];
}

@end
