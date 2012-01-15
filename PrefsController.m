//
//  PrefsController.m
//  GoogleHealthWeight
//
//  Created by Ford Parsons on 10/10/10.
//  Copyright 2010 Ford Parsons. All rights reserved.
//

#import "PrefsController.h"


@implementation PrefsController
@synthesize addOrDeleteBtn;
@synthesize newUser;
@synthesize didCancel;
@synthesize userText;

- (id)init {
    if ([super init]) {
        newUser = true;
        didCancel = false;
    }
    return self;
}

- (IBAction)cancelBtnClicked:(id)sender {
    didCancel = true;
    [[NSUserDefaults standardUserDefaults] setValue:@"" forKey:@"username"];
    [NSApp endSheet:configureSheet];
}

- (IBAction)addOrDeleteBtnClicked:(id)sender {
    didCancel = false;
    if (newUser) {
        [[NSUserDefaults standardUserDefaults] setValue:[userText stringValue] forKey:@"username"];
    } else {
        [[NSUserDefaults standardUserDefaults] setValue:@"" forKey:@"username"];
    }
    
	[[NSUserDefaults standardUserDefaults] synchronize];
	
	[NSApp endSheet:configureSheet];
}
@end
